import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a test.
import { LOOKUP_AGENTS } from '../../../shared/agent-catalog'
import type { ProviderId } from '@shared/types'
import {
  askForAddAccount,
  namedLogin,
  profileLoginLabel,
  useKnownSignIns,
} from '../../accounts'
import { useMachines } from '../../machines/useMachines'
import { hereName } from '../../machines/types'
import { SegmentedSwitch } from '../../components/SegmentedSwitch'
import { HoverNote } from '../../components/HoverNote'
import {
  closeMenu,
  Group,
  LinkOut,
  Notice,
  Row,
  SectionHead,
  SettingList,
  ToolVersion,
  type OptionState,
} from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  errorText,
  missingChannelNote,
  toPrerequisites,
  toProfiles,
  type Prerequisites,
  type ProfilesSnapshot,
  type SectionProps,
  type ToolStatus,
} from '../settings-bridge'
import { useAccountProviderRows } from '../../components/ProviderPicker'
import { AccountsSection, RUN_TITLE } from './AccountsSection'
import { canHaveMore } from './account-agent'
import { DeviceAccounts } from './DeviceAccounts'
import { ServerAccounts } from './ServerAccounts'
import { SetupSection } from './SetupSection'

/**
 * Coding AI — the whole subject, on one pane.
 *
 * The file is `AgentsSection.tsx` and the rail says "Coding AI"; the label has
 * been rewritten twice on review and the id has not moved either time. See the
 * argument beside the `agents` entry in `settings-schema.ts`.
 *
 * ## Three sections became one, and then the one stopped shouting
 *
 * Agents, Accounts and Setup were the same subject split across three rail
 * entries, each spending a paragraph pointing at the other two, so they were
 * merged. The merge kept every group heading it inherited, and the recorded
 * review of 2026-08-19 is what that cost:
 *
 *   > "it's too messy and too difficult to understand… just give a button
 *   > drop-down, add an agent, and there will be a list of them like Gemini,
 *   > Claude Code… If we don't have installed Codex, it should not be on the
 *   > page at all… We might have 100 things, so we cannot show all of them
 *   > here."
 *
 * Two decisions come out of that and they are the shape of this file.
 *
 * **What is on the page is what is on the machine.** The list used to show a
 * missing agent greyed out with a "Get it" link beside it, on the argument that
 * "Codex is missing from this list" is a worse bug report than "Codex is greyed
 * out". That argument lost: a list of three rows where two are dead is a list
 * that has to be read before it can be dismissed, and it does not survive a
 * fourth agent, let alone the hundred he is thinking about. A missing agent is
 * not a row. It is an entry in the Add-accounts menu, which is where somebody
 * goes when they want one they do not have.
 *
 * **Nothing on this pane re-probes by hand.** The "Check again" button is gone.
 * `check` runs from an effect on every visit to the pane, so the button re-ran
 * work that had just been done, one press after the answer landed — a control
 * whose only honest label would have been "again".
 *
 * ## Assembled, not rewritten
 *
 * The Accounts and Setup halves are the *same components* that were the
 * Accounts and Setup panes, rendered here with their own heading suppressed.
 * That is the answer to the risk he named — *"when you reorganize you mostly
 * miss the things and you drop some stuff"* — because nothing is re-typed to be
 * moved, so nothing can be lost in the typing. `nothing-dropped.test.tsx` then
 * checks the result from the outside.
 */

/**
 * The agents, from the one declaration.
 *
 * This was a literal `['claude', 'codex', 'gemini']` here, another in
 * `prerequisites.ts`, and a third in `SETUP_TOOL_IDS`. A fourth agent had to be
 * remembered in all three, and forgetting one produces a pane that quietly
 * disagrees with the New-session picker about which agents exist.
 */
const AGENT_IDS: readonly string[] = LOOKUP_AGENTS.map((entry) => entry.id as string)

/**
 * `STATE_LABEL` was here — Ready / Sign-in needed / Not installed / Unknown,
 * printed down the right of a standing list of every installed agent.
 *
 * The list is gone (see `AddAccountsMenu`) and the word went with it rather
 * than moving, because on this pane it was the same fact twice. Whether an agent can
 * start a session is answered per *login* on every account row below —
 * "Signed in" / "Not signed in", read from that agent's own `auth status` — and
 * an agent-level summary of those rows sat above them saying it again in one
 * word. What is left in the menu is the version, which nothing else says.
 */

/**
 * Suffix for the default-tool picker. Short — it renders inside an `<option>`.
 *
 * This moved here with the picker itself. It was in `GeneralSection` while the
 * row was, which meant the code that knows whether a tool exists lived two
 * files away from the code that lists the tools.
 */
export function optionStateFor(prereq: Prerequisites | null, value: string): OptionState {
  // A plain shell is always available; it is the fallback the main process
  // already falls back to when a requested provider is missing.
  if (value === 'shell' || !prereq) return {}
  const tool = prereq.tools.find((entry) => entry.id === value)
  if (!tool) return {}
  if (tool.state === 'missing') return { disabled: true, suffix: 'not installed' }
  if (tool.state === 'installed-not-authed') return { suffix: 'sign-in needed' }
  return {}
}

/**
 * The agents this pane may draw a row for: the ones the probe found.
 *
 * A function rather than a filter written inline, because the whole of the
 * instruction is in the predicate — *"If we don't have installed Codex, it
 * should not be on the page at all"* — and a predicate a test can call is a
 * rule that cannot be quietly widened back by somebody restoring a "helpful"
 * greyed-out row.
 */
export function agentsPresent(prereq: Prerequisites | null): ToolStatus[] {
  return (prereq?.tools ?? []).filter(
    (tool) => AGENT_IDS.includes(tool.id) && tool.state !== 'missing',
  )
}

/* ------------------------------------------------------------ where they run -- */

/**
 * Which machine's agents this pane is showing.
 *
 * *"Two buttons at the top to switch between this machine and server
 * machines."* The vocabulary is `SERVERS-DESIGN.md`'s and it is deliberately
 * not invented here: a **server** is a computer nobody sits at, as opposed to a
 * *device*, which runs this app at the far end. What the switch offers is
 * therefore "this machine" against "servers" and never "remote", which in this
 * app already means something narrower.
 */
export type AgentScope =
  | 'this-machine'
  | 'servers'
  | `device:${string}`
  /**
   * **One** server, by id — which is a narrower thing than `'servers'` above and
   * had to be, rather than being folded into it.
   *
   * `'servers'` on this pane means *the coding logins on all of them*, which is
   * the right scope for a question about accounts. The Servers pane asks a
   * different question — what is this **one** machine set to do — and every
   * answer it draws is per server: its identity, its sign-in, the folder its
   * sessions start in, the two permissions it holds. A switch whose only buttons
   * were this computer and *Servers* could not name which.
   */
  | `server:${string}`

/**
 * The two seats at the head of the switch — and the one rule for what a seat on
 * a `.settings-scope` switch is called, anywhere in this window.
 *
 * ## The rule
 *
 * **A seat that is one machine carries that machine's name. A seat that is a
 * group of machines carries the group's word. A pane with nothing to say about
 * a machine offers no seat for it at all.**
 *
 * So `Servers` — every server at once, which is the scope this pane's account
 * list answers — stays a word, and every other seat is a name: a paired device
 * is named as the rail names it, one server is named as the list names it, and
 * *this* computer is named by {@link hereName}, which is its hostname with
 * *This Mac* / *This PC* as the fallback for a build whose preload predates the
 * field.
 *
 * ## Why this computer is named rather than pointed at
 *
 * Because the deictic is the complaint. This seat said "This machine" while the
 * MCP servers page — the same control, the same class — said the hostname, and
 * the Servers pane offered no such seat, so one window carried three vocabularies
 * for one computer. Asad, on exactly that confusion, 2026-08-21:
 *
 *   > *"So I'm confused now what is the truth, because this machine is Office
 *   > PC, this machine is this machine where I am, and Office PC is the server.
 *   > So it is showing both, selected one and this one. So I don't know what to
 *   > trust."*
 *
 * A phrase meaning *wherever you are* cannot be resolved by reading it, on a bar
 * where every other button carries a hostname; a name can. `hereName` in
 * `machines/types.ts` is where that argument is written down in full, and it is
 * the same answer the browser's machine picker, the copilot's machine switch and
 * the downloads list already give — so this is one vocabulary joining the rest
 * rather than a fourth being invented.
 *
 * A function rather than a constant because the name is read at render time from
 * `useMachines`, and a module-level constant would have frozen whatever the
 * first read said.
 */
export function scopesFor(here: string): readonly { id: AgentScope; label: string }[] {
  return [
    { id: 'this-machine', label: here },
    { id: 'servers', label: 'Servers' },
  ]
}

/** The scope for one linked device, and the device it names. One spelling. */
export function deviceScope(id: string): AgentScope {
  return `device:${id}`
}

export function deviceOfScope(scope: AgentScope): string | null {
  return scope.startsWith('device:') ? scope.slice('device:'.length) : null
}

/**
 * The scope that should be on screen, given the devices that still exist.
 *
 * A device can be forgotten while its scope is the one selected, and without
 * this the pane draws nothing at all under a button that is no longer in the
 * switch: every button {@link ScopeSwitch} draws would read
 * `aria-pressed="false"`, which is a segmented control with nothing selected.
 *
 * A function rather than the three lines it replaces, because it was those
 * three lines in one pane and is now needed in every pane that carries the
 * switch — and a guard re-typed per pane is a guard the next pane forgets. Pure,
 * so it can be asserted without a DOM: these tests render static markup and run
 * no effects, so the guard inside one was unreachable from a test.
 */
export function scopeAfterDevices(
  scope: AgentScope,
  devices: readonly { id: string }[],
): AgentScope {
  const wanted = deviceOfScope(scope)
  if (wanted === null) return scope
  return devices.some((device) => device.id === wanted) ? scope : 'this-machine'
}

/**
 * The scope for one server, and the server it names. The same one spelling, for
 * the same reason: two places composing `server:${id}` by hand is two places to
 * get the separator wrong, and the failure would be a switch that never matches
 * its own selection.
 */
export function serverScope(id: string): AgentScope {
  return `server:${id}`
}

export function serverOfScope(scope: AgentScope): string | null {
  return scope.startsWith('server:') ? scope.slice('server:'.length) : null
}

/**
 * The buttons at the top of the pane: this machine, the servers, and every
 * device linked to this one.
 *
 * The switch had exactly two buttons and the rail behind the dialog was listing
 * a paired PC with a live session on it at the same moment:
 *
 *   > *"And maybe we can also see the other linked device. Whatever new comes
 *   > here, so we can manage next to them, each of them."*
 *
 * So a device is a scope, named as the rail names it, and the list is whatever
 * `useMachines` is holding — which re-reads on every push and every four
 * seconds, so a machine linked while this window is open joins the switch
 * without it being reopened.
 *
 * `aria-pressed` rather than a tab set: these are not tabs in the ARIA sense —
 * there is no tablist in the rail sense here and the rail itself already owns
 * that role for the sections — they are buttons of which exactly one is on,
 * which is what a segmented control is everywhere else in this app.
 */
export function ScopeSwitch({
  scope,
  here,
  devices = [],
  servers = [],
  fixed,
  label = 'Where these agents run',
  onScope,
}: {
  scope: AgentScope
  /**
   * What this computer calls itself — `MachinesView.here` straight off
   * `useMachines`, which every pane that draws this switch is already reading
   * for its device buttons.
   *
   * Passed raw rather than resolved, so {@link hereName} is applied in one place
   * and a pane cannot accidentally supply a fourth wording: absent, empty, or a
   * build whose preload predates the field all come out as *This Mac* / *This
   * PC*, which is what every other surface in the app calls this computer. See
   * {@link scopesFor} for the rule this is half of. Ignored when a caller passes
   * its own `fixed`, because then there is no *this machine* seat to name.
   */
  here?: string
  /** The linked machines, in the order the rail lists them. */
  devices?: readonly { id: string; name: string }[]
  /**
   * The stored servers, each its own scope.
   *
   * Appended the way `devices` is rather than folded into it, because the two
   * are different kinds of machine in this app's vocabulary and `deviceScope`
   * and `serverScope` mint different ids — a server in the devices list would
   * be a button the Servers pane could never match.
   */
  servers?: readonly { id: string; name: string }[]
  /**
   * The scopes at the head of the switch, before the machines.
   *
   * Defaulted rather than always drawn, so this stays one component instead of
   * two. Coding AI and Scraping take the default — *"two buttons at the top to
   * switch between this machine and server machines"* — and the Servers pane
   * passes `[]`, because on a pane whose every control is a property of one
   * server there is nothing a local machine could be asked.
   *
   * That is the third clause of {@link scopesFor}'s rule rather than an exception
   * to it: a pane offers a seat for this computer when it has something to say
   * about this computer, and names it when it does. What it must not do is offer
   * one under a different word.
   */
  fixed?: readonly { id: AgentScope; label: string }[]
  /**
   * What the group of buttons is, for a screen reader.
   *
   * A prop rather than a second component. This switch is shared — Coding AI
   * and Scraping both draw it, and more panes will — and the one thing that
   * genuinely differs between them is the sentence naming *what* runs in the
   * chosen place. Forking the component to change four words is how two
   * segmented controls come to behave differently; the default is the caller
   * that has been here longest, so no existing call site changes.
   */
  label?: string
  onScope(next: AgentScope): void
}) {
  const entries = [
    ...(fixed ?? scopesFor(hereName({ here: here ?? '' }))),
    ...devices.map((device) => ({ id: deviceScope(device.id), label: device.name })),
    ...servers.map((server) => ({ id: serverScope(server.id), label: server.name })),
  ]
  /*
   * The markup is `SegmentedSwitch`'s rather than this function's, and moving it
   * there changed nothing about what this draws — same class, same `data-on`,
   * same `aria-pressed`, same order.
   *
   * It moved because three other files were hand-rolling the identical eleven
   * lines against the same class, and one of them had already drifted: see the
   * note on `.da-scope` in `components/SegmentedSwitch.tsx`. This is still the
   * control the rest of the app is asked to copy — *"switching pill just like in
   * coding ai page in settings"* — so copying it now means importing it.
   */
  return (
    <SegmentedSwitch
      options={entries}
      value={scope}
      onChange={onScope}
      label={label}
    />
  )
}

/*
 * `AgentList` was here: a standing list of every installed agent, with its
 * version, a status word and — under Codex on this machine — a two-line
 * paragraph about which copy of the binary actually runs.
 *
 * It is deleted rather than shortened, and the sentence it was deleted for is
 * the one he repeated most:
 *
 *   > *"Here it's too messy and too difficult to understand… We might have 100
 *   > things, so we cannot show all of them here. So we will show only mostly
 *   > accounts here."*
 *
 * and, of the paragraph itself:
 *
 *   > *"Remove this full shit. I don't want any kind of long descriptions
 *   > anywhere. Just if somewhere it's very required, give the i icon."*
 *
 * Nothing it said is unreachable. **Which** agents this machine has is the same
 * question the account groups underneath answer — profiles.ts mints one login
 * per installed agent, so an installed agent always has a heading down there —
 * and *whether* one can start a session is answered per login on every row of
 * it. What only this list said is the version and the caveat, and both are in
 * the Add-accounts menu now, which is his own answer to a list that is too long to
 * stand on a page: *"why not just one drop-down to look at it if we need it?"*
 */

/* ------------------------------------------------------------ add accounts -- */

/**
 * What one row of the menu offers, once and for both halves of the row.
 *
 * A closed set rather than a pair of booleans, because the rule underneath is
 * that a row has exactly one action — the state where a row offered two was the
 * **Sign in** / **Add account** pair the review walked into twice.
 */
export type AddAccountsAction = 'add-account' | 'sign-in' | 'install' | 'none'

/** One agent, as the menu draws it. */
export interface AddAccountsRow {
  id: string
  label: string
  /** Where to get it. Only ever read for an agent this machine does not have. */
  url: string | null
  installed: boolean
  /** Which of the two headed runs this row belongs in. */
  run: 'signed-in' | 'not-signed-in'
  /**
   * The logins this agent holds that anybody has named.
   *
   * Empty is the normal answer for two of the three agents: `codex login
   * status` never prints an address and Gemini has no status command at all, so
   * a signed-in row there names nothing rather than borrowing the install's
   * name. See `namedLogin`.
   */
  logins: readonly string[]
  action: AddAccountsAction
}

/**
 * The menu's rows, decided in one place.
 *
 * Two instructions meet here and they are easy to satisfy separately and lose
 * together. The separation:
 *
 *   > *"Whatever is not install or login should be separate, and all the login
 *   > ones should be separate. Proper separation I told you."*
 *
 * and the dead row, which is what the separation was hiding:
 *
 *   > f_0021/f_0022 — "Gemini CLI 0.46.0 — Installed", where **Installed** is a
 *   > label, not a button.
 *
 * So every row that is not signed in carries a live act — **Sign in** for an
 * agent that is here, **Install** for one that is not — and the word
 * "Installed" is gone rather than restyled: it was the right-hand column of a
 * menu whose right-hand column is what can be *done*, and it named a state.
 *
 * A pure function because these are the states no screenshot catches: an agent
 * installed and signed in that cannot hold a second login, and a window with no
 * way to start a session at all. The caller narrows `addable` and `signInable`
 * by whether it actually has a handler, so a row can never be given an action
 * the component then declines to draw.
 */
export function addAccountsRows(state: {
  /** Installed, as the probe found it. */
  present: ReadonlySet<string>
  /** Installed, able to take another login, and there is somewhere to add it. */
  addable: ReadonlySet<string>
  /** Has at least one login the agent itself reports as signed in. */
  signedIn: ReadonlySet<string>
  /** Installed, has an install login, and this window can open a session. */
  signInable: ReadonlySet<string>
  /** Agent id → the logins of it that are named. */
  logins?: Readonly<Record<string, readonly string[]>>
}): AddAccountsRow[] {
  return LOOKUP_AGENTS.map((entry) => {
    const installed = state.present.has(entry.id)
    const signedIn = state.signedIn.has(entry.id)
    const action: AddAccountsAction = !installed
      ? entry.url
        ? 'install'
        : 'none'
      : signedIn
        ? // Signed in already: the only thing left to add is another login, and
          // Gemini keeps one per machine — so that row names what is there and
          // offers nothing, which is honest where **Add account** would open a
          // popup with its own radio disabled.
          state.addable.has(entry.id)
          ? 'add-account'
          : 'none'
        : // Here and not signed in. Signing the install's own login in is the
          // act that matches the row, and it is the same act the account row
          // below offers; adding a second login is the fallback for an agent
          // with no install login to sign in.
          state.signInable.has(entry.id)
          ? 'sign-in'
          : state.addable.has(entry.id)
            ? 'add-account'
            : 'none'
    return {
      id: entry.id,
      label: entry.label,
      url: entry.url,
      installed,
      run: signedIn ? 'signed-in' : 'not-signed-in',
      logins: state.logins?.[entry.id] ?? [],
      action,
    }
  })
}

/** The heading over each run, in the same words the accounts list uses. */
export const MENU_RUN_TITLE: Record<AddAccountsRow['run'], string> = {
  'signed-in': RUN_TITLE['signed-in'],
  'not-signed-in': RUN_TITLE['not-signed-in'],
}

/**
 * "Add accounts", as a menu rather than as a page of rows.
 *
 * A `<details>` and not a floating menu, for a reason that outlives the styling:
 * the whole of this window is asserted through `renderToStaticMarkup`, which
 * runs no effects and has no DOM to click in, so a menu built out of state and a
 * portal is a menu whose contents no test can read. A disclosure is in the
 * markup either way, is keyboard-operable and dismissable without a line of
 * JavaScript, and — the part that matters here — costs the closed pane nothing.
 *
 * ## Every row does something, which it did not
 *
 * The rows were `<li><span>name</span><span>Installed</span></li>`. No button,
 * no handler, `cursor: auto` — a menu you could open and could not use, which
 * on a machine with all three agents on it was three dead lines behind a control
 * called **Add**. Measured on 2026-08-20: clicking a row left the disclosure
 * open and changed nothing.
 *
 * The fix is not to hide the rows. It is that an installed agent has an answer
 * to "add this", and he said what it is in the same breath as asking for the
 * menu:
 *
 *   > *"If we add Claude Code, and then we will have relevant stuff, add
 *   > account things and all of this."*
 *
 * So an installed agent opens the Add-account popup with that agent already
 * chosen, and an agent that is not installed keeps its install link, which was
 * always a real action. Both halves of the menu are live in every state, and no
 * state of this machine can produce a row that does nothing.
 *
 * ## What is deliberately *not* here
 *
 * There is no "added agents" list to be on or off, and no Remove. Adding and
 * installing are the same act in his words — *"if we want to install from the
 * drop-down, we will add it"* — and the page already draws only what the probe
 * found, which is the whole of *"if we don't have installed Codex, it should not
 * be on the page at all"*. A per-agent show/hide switch would be a second
 * meaning for "added", stored in a file, controlling a page he asked to have
 * *fewer* controls on.
 *
 * ## And what came *into* it, 2026-08-20
 *
 * The version, and the one caveat an agent can carry. Both were a standing list
 * on the pane above this — see the note where `AgentList` used to be — and this
 * is where he said a list that long belongs: *"why not just one drop-down to
 * look at it if we need it?"* The caveat is behind an ⓘ rather than printed,
 * which is the other half of the same instruction.
 *
 * ## And the two runs, 2026-08-21
 *
 * *"Whatever is not install or login should be separate, and all the login ones
 * should be separate."* The menu was three flat rows naming CLIs and no
 * accounts. It is two headed runs now, the same two the account list above it
 * has, and a signed-in row names the logins it holds where the agent named
 * them. `addAccountsRows` decides both.
 */
export function AddAccountsMenu({
  present,
  addable,
  signedIn = new Set<string>(),
  signInable = new Set<string>(),
  logins,
  agents = [],
  onAddAccount,
  onSignIn,
}: {
  present: ReadonlySet<string>
  /**
   * Which of the installed agents can actually take another login.
   *
   * Gemini cannot — it keeps one per machine, measured in
   * `main/provider-accounts.ts` — so its row offers nothing rather than
   * offering **Add account** and landing somebody in a popup where its own
   * radio is disabled. Absent means "not answered yet", which reads the same
   * way as "no": a row that says nothing is always honest, and a row that
   * promises an account that cannot exist is not.
   */
  addable?: ReadonlySet<string>
  /** Which agents hold a login their own CLI reports as signed in. */
  signedIn?: ReadonlySet<string>
  /** Which agents have an install login this window could open a sign-in for. */
  signInable?: ReadonlySet<string>
  /** Agent id → the logins of it anybody has named, for the signed-in run. */
  logins?: Readonly<Record<string, readonly string[]>>
  /**
   * What the probe found, for the two facts a row can carry beyond its name.
   *
   * The version, which nothing else in this window says; and `note`, which
   * today says exactly one thing — that this agent runs from a copy other than
   * the one on your PATH — and is the reason it is kept at all: somebody never
   * told that finds `codex` failing in their own terminal and working here, and
   * stops trusting the app rather than the install.
   */
  agents?: readonly ToolStatus[]
  /** Open the Add-account popup for this agent. Absent draws no action. */
  onAddAccount?(provider: ProviderId): void
  /**
   * Sign the agent's own install login in, which opens a session on it.
   *
   * Absent draws no **Sign in**, for the reason every capability in this window
   * is optional: a settings pane rendered without a way to start a session
   * cannot sign anything in, and a button that only apologises is worse than no
   * button.
   */
  onSignIn?(provider: ProviderId): void
}) {
  const rows = addAccountsRows({
    present,
    // Narrowed by whether there is anywhere for the press to go, so the row's
    // action and what this component draws can never disagree.
    addable: onAddAccount ? (addable ?? new Set()) : new Set(),
    signedIn,
    signInable: onSignIn ? signInable : new Set(),
    logins,
  })
  const runs: AddAccountsRow['run'][] = ['signed-in', 'not-signed-in']

  return (
    <details className="settings-addmenu">
      <summary>Add accounts</summary>
      {runs.map((run) => {
        const mine = rows.filter((row) => row.run === run)
        // No heading over an empty run — the same rule the account list follows,
        // and on a fresh machine it would otherwise be a heading over nothing
        // directly under a control called Add.
        if (mine.length === 0) return null
        return (
          <div key={run} className="settings-addmenu-run" data-run={run}>
            <h5 className="settings-addmenu-run-title">{MENU_RUN_TITLE[run]}</h5>
            <ul>
              {mine.map((row) => {
                const tool = agents.find((entry) => entry.id === row.id)
                /* The version sits inside the button on a row that has one and
                   beside the name on a row that does not, so it is in the same
                   column either way. `ToolVersion` draws nothing at all for a
                   tool with no version, which is what a menu rendered before the
                   probe answers looks like. */
                const name = (
                  <span className="settings-addmenu-name">
                    {row.label}
                    {row.installed && tool ? <ToolVersion tool={tool} /> : null}
                    {/* The logins themselves, which is the whole of *"if I have
                        any account login here, it should be showing that one"*.
                        Nothing at all where the agent named nobody — a signed-in
                        row under the **Signed in** heading has already said the
                        only thing that is true. */}
                    {row.logins.length > 0 && (
                      <span className="settings-addmenu-login">{row.logins.join(', ')}</span>
                    )}
                  </span>
                )
                const press = row.action === 'sign-in' ? onSignIn : onAddAccount
                return (
                  <li key={row.id}>
                    {press && (row.action === 'add-account' || row.action === 'sign-in') ? (
                      /* The whole row is the button, because the whole row is
                         what a person aims at in a menu — and it is a `<button>`
                         rather than a clickable `<li>` so that it is reachable by
                         keyboard and announced as an action, which is exactly
                         what the dead version was not. */
                      <button
                        type="button"
                        className="settings-addmenu-row"
                        onClick={(event) => {
                          closeMenu(event)
                          press(row.id as ProviderId)
                        }}
                      >
                        {name}
                        <span className="settings-addmenu-have">
                          {row.action === 'sign-in' ? 'Sign in' : 'Add account'}
                        </span>
                      </button>
                    ) : (
                      <>
                        {name}
                        {/* An agent with no page to send anybody to is still
                            worth listing: its absence from the account groups is
                            the fact, and a menu that silently dropped it would be
                            the greyed-out row's problem in a smaller box.

                            "Installed" was the third thing this column could say
                            and it is gone: the column is what can be *done* with
                            a row, and that word named a state. Which agents are
                            installed is what the two runs and the version say. */}
                        {row.action === 'install' && row.url && (
                          <LinkOut href={row.url}>Install</LinkOut>
                        )}
                      </>
                    )}
                    {/* Outside the row's button, never inside it: a `HoverNote` is
                        itself a `<button>`, and a button inside a button is markup no
                        browser agrees about.

                        In a slot of its own, and the slot is there whether the dot is
                        or not — a fixed width holding the dot *and* the hidden span
                        it puts its text in. Measured without it: the right edge of
                        "Add account" landed at 692 on the one row with a caveat and
                        696 on the two without, because the screen-reader span is a
                        1px child of the row. */}
                    <span className="settings-addmenu-tail">
                      {row.installed && tool?.note && (
                        <HoverNote label={row.label}>{tool.note}</HoverNote>
                      )}
                    </span>
                  </li>
                )
              })}
            </ul>
          </div>
        )
      })}
    </details>
  )
}

/* ----------------------------------------------------------------- section -- */

export function AgentsSection(props: SectionProps) {
  const { values, save, bridge, loading } = props
  const meta = sectionMeta('agents')
  const [scope, setScope] = useState<AgentScope>('this-machine')
  const [prereq, setPrereq] = useState<Prerequisites | null>(null)
  const [profiles, setProfiles] = useState<ProfilesSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)

  /*
   * There is no `checking` flag any more, and its absence is the fix rather
   * than a tidy-up. It started false, was set true inside the effect, and the
   * list read `agents.length === 0 && !checking` for its empty state — so the
   * very first paint, before any effect has run, matched the empty state and
   * printed it for a frame. That was survivable while the sentence read
   * "Nothing reported yet"; it is not now that it reads "No agent installed
   * yet", which is a claim about somebody's machine made before anything looked
   * at it. `prereq === null` is the same question asked of the answer itself,
   * and it is false on the first paint for the right reason.
   */
  const check = useCallback(() => {
    if (!bridge.checkPrerequisites) return
    void bridge.checkPrerequisites().then(
      (raw) => setPrereq(toPrerequisites(raw)),
      (cause: unknown) =>
        setError(errorText(cause, 'Could not check which agents are installed.')),
    )
  }, [bridge])

  useEffect(check, [check])

  useEffect(() => {
    if (!bridge.listProfiles) return
    void bridge.listProfiles().then(
      (raw) => setProfiles(toProfiles(raw)),
      () => setProfiles(null),
    )
  }, [bridge])

  const chooseProfile = useCallback(
    (id: string) => {
      if (!bridge.setDefaultProfile) return
      // Optimistic, like every other control here — the list is short and the
      // write is a JSON file.
      setProfiles((current) => (current ? { ...current, defaultProfileId: id } : current))
      void bridge.setDefaultProfile(id).then(
        (raw) => {
          const next = toProfiles(raw)
          if (next) setProfiles(next)
        },
        (cause: unknown) => setError(errorText(cause, 'Could not change the default profile.')),
      )
    },
    [bridge],
  )

  /*
   * Sign-in answers this window has already read — see `useKnownSignIns`. A
   * read, never a probe: this pane draws on open and the picker below has one
   * option per account.
   */
  const knownSignIns = useKnownSignIns()

  /*
   * Which agents can hold more than one login, measured rather than assumed.
   *
   * The same rows the Accounts pane below and the Add-account popup read, so
   * the picker cannot come to offer an account the row underneath calls
   * one-login-only. Gated on the pane being on screen, like every other probe
   * here.
   */
  const providerRows = useAccountProviderRows(scope === 'this-machine')

  /*
   * The machines linked to this one, for the switch at the top.
   *
   * The window's own hook rather than a read of its own: it re-reads on every
   * `machines:state` push and every four seconds besides, which is what makes
   * *"whatever new comes here"* true without this pane owning a subscription of
   * its own. It dials nothing — connecting is the main process's job — so
   * having it mounted costs a settings pane a list read.
   */
  const machines = useMachines()
  const devices = machines.machines.map((row) => ({ id: row.machine.id, name: row.machine.name }))
  const device = machines.machines.find((row) => row.machine.id === deviceOfScope(scope)) ?? null

  /*
   * A device that was forgotten while its scope was the one on screen.
   *
   * Without this the pane would draw nothing at all under a button that is no
   * longer in the switch — every scope button `ScopeSwitch` draws would read
   * `aria-pressed="false"`, which is a segmented control with nothing selected.
   */
  useEffect(() => {
    setScope((current) =>
      scopeAfterDevices(
        current,
        machines.machines.map((row) => row.machine),
      ),
    )
  }, [machines.machines])

  const agents = agentsPresent(prereq)
  const present = new Set(agents.map((tool) => tool.id))
  /*
   * Installed *and* measured able to hold another login.
   *
   * `canHaveMore` alone is not enough here, because it answers *true* for a row
   * it has never heard of — the right reading where an unknown agent must not
   * be blocked, and the wrong one on the first paint, where no row has arrived
   * yet and every agent would briefly offer **Add account** before Gemini's
   * flipped back to Installed. A row has to exist and say yes.
   */
  const addable = new Set(
    agents
      .filter((tool) => providerRows.some((row) => row.id === tool.id && row.canAdd))
      .map((tool) => tool.id),
  )
  // profiles.ts synthesises the user's own install as `system`, so this is
  // never empty once the list has loaded.
  /*
   * The accounts this picker may offer, which is not all of them.
   *
   * It listed every account of every agent, including **Your own Gemini CLI
   * install** — and Gemini keeps one login per machine, so choosing it changes
   * which login exactly nothing uses. That is an option over nothing, in a
   * picker whose own ⓘ then had to explain that some of its options are
   * ignored. `canHaveMore` is the same reading the Accounts rows use for "is
   * there a choice to be made here at all", so the two cannot come to disagree.
   */
  const profileList = (profiles?.profiles ?? []).filter(
    (profile) => profile.provider === null || canHaveMore(providerRows, profile.provider),
  )
  const defaultProfileId = profiles?.defaultProfileId ?? 'system'

  /*
   * Which agents hold a login that is signed in, and what those logins are
   * called — the two facts the menu's own grouping is built from.
   *
   * Read from the sign-in store rather than asked for: the account list six
   * inches below this probes every account on open and publishes each answer,
   * so this is the same answer that list is drawing, arriving at the same
   * moment. Nothing here starts a process; an agent nobody has asked about is
   * simply not in the signed-in run yet, which is the honest state and the one
   * that resolves on its own.
   */
  const signedIn = new Set<string>()
  const logins: Record<string, string[]> = {}
  for (const profile of profiles?.profiles ?? []) {
    if (profile.provider === null) continue
    if (knownSignIns[profile.id]?.state !== 'signed-in') continue
    signedIn.add(profile.provider)
    const named = namedLogin(profile, knownSignIns[profile.id])
    if (named !== null) (logins[profile.provider] ??= []).push(named)
  }

  /*
   * The agents whose own install login this window could sign in.
   *
   * Three conditions, and all three are about whether the press can land: the
   * agent is on the machine, `profiles.ts` has minted a login for it, and this
   * window can open a session — which is what signing in *is*, because the
   * agent's own flow runs inside a terminal and this app never touches a
   * credential.
   */
  const signInable = new Set(
    agents
      .filter((tool) =>
        (profiles?.profiles ?? []).some(
          (profile) => profile.provider === tool.id && profile.system,
        ),
      )
      .map((tool) => tool.id),
  )

  /** The install login of one agent, which is what **Sign in** opens a session on. */
  const signInInstall = (provider: ProviderId): void => {
    const profile = (profiles?.profiles ?? []).find(
      (entry) => entry.provider === provider && entry.system,
    )
    if (!profile) return
    props.startSession?.({ profileId: profile.id, provider })
  }

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {/* Named, not pointed at — `scopesFor` carries the rule and `hereName` the
          complaint that produced it. `machines` is already read above for the
          device buttons, so this costs the pane nothing. */}
      <ScopeSwitch scope={scope} here={machines.here} devices={devices} onScope={setScope} />

      {scope === 'servers' ? (
        <ServerAccounts />
      ) : device !== null ? (
        <DeviceAccounts device={device} />
      ) : (
        <>
          {/* Every error this pane can raise is about *this* machine — a probe
              of its PATH, a write to its profiles file — so it belongs on the
              half that is about this machine. Left outside the switch it would
              sit over a panel about somebody's server, describing something
              that is not on screen. */}
          {error && <Notice tone="error">{error}</Notice>}

          {/*
            One group, untitled, holding the two questions a session answers
            before it starts and the list of what can answer them. It used to be
            two headed groups — "New sessions" and "What is installed" — with a
            button under the second, and the headings were most of what made the
            pane read as three pages stacked.
          */}
          <Group>
            <SettingList
              section="agents"
              values={values}
              save={save}
              disabled={loading}
              optionStates={{
                'agents.defaultProvider': (value) => optionStateFor(prereq, value),
              }}
            />

            {bridge.listProfiles && (
              <Row
                /*
                 * "Run them as" was the label, and it was the wrong end of the
                 * sentence: *"primary account, choose primary account or this
                 * kind of words, or default account. That will be the better
                 * words instead of run them as."* The line of help under it is
                 * gone with it — the row is a picker of accounts under a label
                 * that says which account, and a sentence restating that is the
                 * kind of statement this whole pass is removing. What only the
                 * ⓘ can say, because it is a genuine limit rather than a
                 * description, stays behind the ⓘ.
                 */
                label="Primary account"
                /*
                 * The limit, said accurately.
                 *
                 * It read *"Claude Code only. Other agents ignore this…"*,
                 * which was false in one direction and contradicted by the
                 * picker in the other: `resolveProfileId` skips a stored default
                 * whose agent is not the one starting, so a Codex account here
                 * really is used by Codex sessions — while the list underneath
                 * offered Codex and Gemini rows the sentence said were ignored.
                 * One default is stored, so what it cannot do is be two things
                 * at once, and that is what an ⓘ is for.
                 */
                more="One account, and only sessions of the agent it is a login of use it. Choosing an account of another agent replaces this one rather than sitting beside it."
                htmlFor="settings-default-profile"
                control={
                  <span className="settings-select-wrap">
                    <select
                      id="settings-default-profile"
                      className="settings-select"
                      value={defaultProfileId}
                      disabled={profileList.length === 0 || !bridge.setDefaultProfile}
                      onChange={(event) => chooseProfile(event.target.value)}
                    >
                      {/*
                        The login, not the key it is filed under.

                        This read `Default — your own install`, `Default (Codex
                        CLI) — your own install`, and so on: "Default" is what
                        `systemProfileId` mints for the machine's own install,
                        it is identical on every install of this app, and it is
                        not a name anybody chose. `profileLoginLabel` prints the
                        address when the agent named one, and otherwise says
                        which install this is.

                        Nothing here probes: a `<select>` that spawned a CLI per
                        option would cost three processes to open.
                      */}
                      {profileList.map((profile) => (
                        <option key={profile.id} value={profile.id}>
                          {profileLoginLabel(profile, knownSignIns[profile.id])}
                        </option>
                      ))}
                    </select>
                  </span>
                }
              />
            )}

            {!bridge.checkPrerequisites && (
              <Notice tone="warn">{missingChannelNote('Checking installed agents')}</Notice>
            )}
          </Group>

          {/*
            The Accounts pane, in place. `head={false}` because this page already
            has a heading and the rail entry that used to carry this one is gone.

            **Add accounts** is its foot, and that is the whole of D10. The foot held
            a primary button called *Add account*, directly under a row carrying a
            button called *Sign in*, and the two were the pair he collided with:

              > *"And why do we have see sign in here separately, add account
              > here separately? … Let's try from here, add of sign in. It's also
              > taking me same place."*

            They did lead to the same place, so one of them goes. The one that
            survives is the one he described — *"we just give a button drop-down,
            add app, and they will add app… If we add Claude Code, and then we
            will have relevant stuff, add account things"* — and it is not a
            second blue button beside the row's, so nothing on this pane is now
            two doors to one act. It is passed down rather than rendered here so
            it lands *inside* the list's own foot; `AccountsSection` cannot import
            it, because this module already imports `AccountsSection`.
          */}
          <AccountsSection
            {...props}
            head={false}
            addAccounts={
              bridge.checkPrerequisites && error === null ? (
                <AddAccountsMenu
                  present={present}
                  addable={addable}
                  signedIn={signedIn}
                  signInable={signInable}
                  logins={logins}
                  agents={agents}
                  onAddAccount={(id) => askForAddAccount(id)}
                  onSignIn={props.startSession ? signInInstall : undefined}
                />
              ) : null
            }
          />

          {/*
            And Setup: the coding tools that are not agents. Its own "the agent
            CLIs are in Agents" block has gone — they are on this page, above.
          */}
          <SetupSection {...props} head={false} />
        </>
      )}
    </>
  )
}
