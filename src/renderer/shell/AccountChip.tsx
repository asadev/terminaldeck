import { useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { ProviderId } from '@shared/types'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// aliases, and this component's render tests import it directly.
import { AGENT_CATALOG, type AgentEntry } from '../../shared/agent-catalog'
import { useChipMenu } from './chip-menu'
import { isolationNotice } from '../components/ProfilePicker'
import { HoverNote } from '../components/HoverNote'
import { ProviderBadge } from '../components/ProviderBadge'
import { providerOption } from '../components/ProviderPicker'
import { chipMode, useAgentPresence, type ChromeSession } from './agent-presence'
import {
  accountForFolder,
  accountIdentity,
  accountsBridge,
  announceAccountsChanged,
  askForAddAccount,
  isSystemAccountId,
  profileLoginLabel,
  renameAccount,
  signInStateSummary,
  useAccountIdentity,
  useAccounts,
  useSessionAccount,
  MAX_ACCOUNT_NAME_LENGTH,
  type AccountView,
} from '../accounts'
import './AccountChip.css'

/**
 * Which account a session runs as, beside the folder it runs in.
 *
 * Asad asked for both choices in one place, before anything is typed:
 *
 *   > "when I start a new session I can choose any of my logged in account and
 *   > the folder and I can start a new session"
 *
 * New session still starts immediately in the last folder — that was the
 * earlier ask and it stands. This is the other half of the same line under the
 * session's name: the folder chip says where, this says who, and both are one
 * click from the same spot.
 *
 * ## Over a running session it switches *that* session
 *
 * This is the half that was wrong, and it was wrong in a way that read as a
 * bug even though every line of it was true. Asad, 2026-08-17:
 *
 *   > *"when I change account from the dropdown it starts a new session with
 *   > that account, instead of changing it in the same session."*
 *
 * The constraint the old behaviour was built on is real and has not gone away:
 * an account is a config directory handed to the agent process at spawn — see
 * `profiles.ts`, where setting it chooses the credential *store* and not merely
 * a directory — and a process's environment cannot be rewritten after it
 * starts. So a running agent genuinely cannot change account. Something has to
 * restart.
 *
 * What was wrong was *which* thing restarted. The menu answered "this session
 * cannot change" by opening a second session somewhere else, leaving the person
 * with two tabs, in one folder, on two accounts, and the job of closing the one
 * they had been using. `main/session-switch.ts` is the other answer: the same
 * tab, in the same place on the bar, with the process underneath it stopped and
 * replaced by one running as the other account.
 *
 * Three things follow, and they are why this menu now has two modes rather than
 * one:
 *
 *  - **It only switches a session it is actually about.** With `session` and
 *    `onSwitchAccount` both in hand over a running agent, a row switches. Every
 *    other caller — the two that ask about a *folder*, and a pane bar that has
 *    no session to hand — keeps the old behaviour exactly, because for them
 *    there is nothing to switch and starting one is the only thing a click
 *    could mean.
 *  - **An account is a login of one agent**, so only accounts of the agent this
 *    session is running can run it. A Codex account cannot be handed to a Claude
 *    session; `resolveProfileId` declines that quietly, which is what used to
 *    make picking one look like the app ignoring the click. Those rows stay
 *    visible — they are still worth seeing, and still renameable — and stop
 *    being buttons, with the reason above them.
 *  - **Nothing happens until it has been described.** The row opens a sheet
 *    saying what will be stopped and what becomes of the conversation, and the
 *    conversation is the part nobody can guess: a transcript lives under the
 *    *account's* config directory, so it does not travel. That was measured
 *    rather than assumed — the commands and their output are at the top of
 *    `main/session-switch.ts` — and a restart nobody expected is the complaint
 *    itself, so the description comes first or the fix is only half made.
 *
 * ## Nothing here claims a login it has not seen
 *
 * The state beside each name is read by running the agent's own `auth status`
 * under that account's config directory when the menu opens — see
 * `profiles-signin.ts`. Until an answer arrives the row says "Checking…", and
 * an answer that could not be read says "Unknown". A tick is only ever drawn
 * for an account the agent said it was signed into.
 *
 * ## Which agent, as well as which login
 *
 *   > "in the dropdown we can see which account is connected — but next to it we
 *   > should also see the logo of the LLM."
 *
 * The name on a row is a word somebody typed, and "Work" is a legal name on
 * every agent here — so once the list holds accounts of more than one, the name
 * stops being enough to tell them apart. `ProviderBadge` draws the mark; this
 * puts it on the button and on every row, which is the only place in the window
 * where the running session's account is named at all.
 *
 * The mark is not decoration in the menu either: picking a row starts a session
 * *on that account's own agent*, so it is also what the row is promising. That
 * is why `onPick` carries the provider — see below.
 *
 * ## …including the login it cannot give you
 *
 * An account is a config directory handed to the agent at spawn, so it only
 * means anything for an agent that reads one. `supportsProfiles` in
 * `main/profiles.ts` is the authority: Claude and Codex each have a variable
 * that has been watched to move a login, a plain shell has no login to isolate,
 * and Gemini's variable moves its settings but not its token — two Gemini
 * accounts would address one keychain entry, so the second sign-in would
 * overwrite the first rather than sit beside it. `provider-accounts.ts` records
 * how each of those was measured.
 *
 * This menu used to offer the rows regardless. With the default coding tool set
 * to Plain shell — which is a setting, not an edge case — picking an account
 * opened a session, `host-core.ts` correctly declined to label it, and the chip
 * snapped back to the default account's name. The click did nothing and said
 * nothing, which is the dead control the design brief forbids and, worse, looks
 * exactly like the app quietly sharing one login between two accounts.
 *
 * So the menu asks what a new session here would actually run and, when that
 * agent has no account to give, says so and stops offering the choice.
 * `isolationNotice` is the same sentence the new-session dialog already prints,
 * imported rather than reworded so the two surfaces cannot drift apart.
 *
 * ## Renaming happens where the name is
 *
 *   > "The account dropdown inside a session shows the name an account was
 *   > given and offers no way to change it."
 *
 * The name on a row here is the only place most people ever *see* an account,
 * and it was the one place they could not correct it — the rename lived three
 * screens away in Settings. Each row now carries a Rename button that turns it
 * into a field in place.
 *
 * It is not a second implementation. `renameAccount` in `accounts.ts` is the
 * one that both this and the Accounts screen call: it owns the trim, the length
 * cap, the "same name is not a rename" rule and the re-read of the list
 * afterwards. Growing a copy here is exactly how the two would come to disagree
 * about whether a blank name means "clear it" — and the main process will
 * happily store an account called `''`, which neither surface can then show.
 *
 * The button was drawn on every row and worked on none of them. `renameProfile`
 * refused any system id outright, and on a machine where nobody has added a
 * second login *every* account is a system one — so every press came back with
 * "the default profile cannot be renamed", as a rejected IPC invoke, which is
 * the failure shape that reaches a person as `Error invoking remote method`.
 * `profiles.ts` now stores a display name for those too; the refusal it
 * replaces was guarding the id and the config directory, which are still
 * generated and still untouchable from here.
 *
 * Whatever does come back, it comes back under the field. A collision is a
 * correction to make in the box you are typing in, not a notice at the bottom
 * of a list of other people's accounts.
 *
 * ## A shell has no account, so it is offered an agent instead
 *
 *   > "Starting a session gives you a plain shell. Today that shell still shows
 *   > the chat/terminal switch and the account dropdown — both of which mean
 *   > nothing until an agent is running in it. … Put a Run Claude button there
 *   > instead."
 *
 * An account is a config directory handed to an agent, so with no agent in the
 * session there is nothing for this control to be about — the chip was showing
 * the account a *future* session would use, on a terminal that is not going to
 * use one. In that state the same slot is a Run button, and it does the thing
 * the command does rather than telling you the command: the agent's own
 * command, typed into the session's own pty, exactly as if it had been typed in
 * the terminal view.
 *
 * **Which** agent is the person's default one, read out of the catalogue rather
 * than written into this file — see {@link runnableAgent} for the whole of that
 * argument, which is the naming rule and a correctness bug at the same time.
 *
 * ## The chip says who, not which record
 *
 *   > "inside the terminal page it is still showing selected account as Default
 *   > and not showing the email ID. … It should show clearly which one is
 *   > actually selected there. It just says Default."
 *
 * "Default" is the name `main/profiles.ts` generates for the machine's own
 * install of an agent. It is an internal key — it is the same word for every
 * user, it is the same word for a login that works and one that has expired,
 * and on a machine where nobody has added a second account it is the *only*
 * word the chip ever showed. So the one control whose entire job is saying
 * which login a session is running as was saying nothing at all.
 *
 * What it shows instead is {@link accountIdentity}, whose ladder is documented
 * where it lives: the address the agent's own CLI named, failing that a name a
 * person chose, failing that the state that was actually read. Nothing in that
 * ladder invents an address and nothing in it falls back to the profile key.
 *
 * Getting the address costs a probe, and this chip is mounted for the whole
 * life of every session — which is exactly why the menu's list is only checked
 * when it opens. {@link useAccountIdentity} is the narrow exception: **one**
 * account, the one on screen, asked once per id and memoised for thirty seconds
 * in the main process. Three processes for a control nobody clicked is a cost;
 * one process for the only fact the control exists to state is the control.
 *
 * The moment an agent is running the button gives way to the account chip. That
 * swap is driven by {@link useAgentPresence}, never by what was typed: an agent
 * exits and leaves the shell behind, and a control keyed off the keystroke
 * would stay switched for the rest of the tab's life.
 *
 * While presence is *unknown* — the first few hundred milliseconds, or a build
 * with no controls channel — neither is drawn. Guessing wrong in that direction
 * is not free: pressing Run at a session that already has an agent in it does
 * not start anything, it submits the command as a prompt.
 */

interface Props {
  /**
   * The account the session on screen is running as, when it has one.
   *
   * Comes off `SessionMeta`, which the main process fills in at spawn from the
   * profile it actually resolved. Null for a session with no account — a plain
   * shell, or an agent whose config directory this app cannot redirect — and
   * for those the chip shows what a *new* session here would use instead.
   *
   * `provider` is what this session was launched as, and it is the only source
   * for the mark on the button that is available while the menu is shut: the
   * account list is not read until the menu opens, deliberately, because
   * reading it spawns a process per account and this chip is on screen for the
   * whole life of every session.
   */
  current: { id: string; name: string; provider?: ProviderId } | null
  /**
   * The account this session is waiting to become, when a switch has been armed
   * for the next message.
   *
   * Named rather than flagged, because "a switch is pending" is not what
   * somebody needs to read — they picked an account by name and want to see
   * that name. Null is the ordinary case and draws nothing.
   *
   * It sits beside `current` and never replaces it: the session is genuinely
   * still running as `current`, and drawing the incoming account as though it
   * had already happened is the one thing this feature is not allowed to do.
   */
  pendingAccount?: string | null
  /** The folder a session started from this menu will run in. */
  projectPath: string | null
  /**
   * The agent a session started from this menu would run.
   *
   * Used only to explain when an account cannot apply — see the module note.
   * Undefined means "not known", which is treated as "no objection": a notice
   * nobody can act on is worse than no notice.
   */
  provider?: ProviderId
  /**
   * The session this chip is sitting under, when the toolbar is showing one.
   *
   * Only used to answer "is there an agent in it" — see the module note.
   * Omitted, the chip behaves exactly as it did before that question existed:
   * it is the account picker, always. That is deliberate rather than lazy; the
   * two callers that render this without a session in play are asking about a
   * folder, and a folder cannot have an agent running in it.
   */
  session?: ChromeSession | null
  /**
   * Start the agent in `session`. Optional: without it the button types the
   * command into the session's own pty itself, which is the same thing the
   * terminal view would do with the same keystrokes.
   */
  onRunAgent?(sessionId: string): void
  /**
   * Start a session in `projectPath` under this account, on that account's own
   * agent.
   *
   * The second argument is what makes the row do anything at all now that the
   * list holds accounts of more than one agent. Started on the *default* agent
   * instead, a Codex account reaches `resolveProfileId`, which rightly refuses
   * to run one agent's login under another's session and falls back to the
   * machine's own — so the click opened a session under the wrong account and
   * the chip snapped back, saying nothing. Undefined for an account whose agent
   * the main process did not name, which means "use the default" and is the
   * only honest request this window can make about it.
   */
  onPick(accountId: string, provider?: ProviderId): void
  /**
   * Run **this** session as that account, instead of starting another one.
   *
   * The whole of the reported fix, and it is optional for a reason rather than
   * out of caution: two of this component's callers are asking about a folder
   * and one is a pane bar with no session in hand, and for all three there is
   * nothing on screen to switch — so a click there can only mean "start one",
   * which is what {@link onPick} already does. Passing this is what says "there
   * is a running session here and I can replace it"; without it the menu is
   * exactly what it was.
   *
   * It is handed the session id as well as the account because the switch is a
   * main-process operation on a specific pty, and this component deliberately
   * knows nothing about which one is on screen beyond the `session` it was
   * given.
   */
  onSwitchAccount?(sessionId: string, accountId: string): void
  /** Open the Accounts screen — add one, rename one, sign one in. */
  onManage(): void
}

const CHEVRON = 'M6.5 9.5 10 13l3.5-3.5'

/**
 * The mark on the account this session is already running as.
 *
 *   > "It should show clearly which one is actually selected there."
 *
 * It did not. The current row was distinguished by its *name* being drawn in
 * the accent colour and by nothing else — which is a difference you can only
 * see by comparing it against the rows above and below, is invisible to anyone
 * who cannot separate those two greys, and disappears entirely when the rows
 * are inert. A tick is the mark every menu on this platform uses for the item
 * in force, and it is the same shape whether the row can be pressed or not.
 */
const TICK = 'M4.5 10.5 8 14l7.5-8'

/**
 * Which agent this button would start, or null when there is none to start.
 *
 * ## Why this is looked up rather than written down
 *
 * The button used to be spelled `Run Claude`, and the label was a literal
 * string sitting in the JSX four hundred lines below. That was defensible on
 * the day it was typed — the command it sent was the literal `claude`, so the
 * label was the command, and renaming the label without changing the keystrokes
 * would have made the button lie about what it does. The defence was even
 * written into this file.
 *
 * It was still wrong, and the review says why in a sentence drawn wider than
 * the setup flow it was said about:
 *
 *   > *"You should not mention in any settings or any pop-up a specific tool or
 *   > LLM, because they can use some other also."*
 *
 * This button is on the toolbar of **every shell session**, which is the state
 * every new session starts in. A person whose default agent is Codex was being
 * offered, on their own session, a button naming somebody else's product — and
 * pressing it would have typed `claude` at a machine that may not have it
 * installed. The label was not merely branded, it was about to be *wrong*,
 * which is the exact decay the naming guard exists to catch.
 *
 * So the fix is not a rename. Both halves — the word on the button and the
 * keystrokes it sends — now come from {@link AGENT_CATALOG}, keyed by the agent
 * the person actually chose, and they cannot disagree because they are read
 * from the same row. Naming a thing somebody chose is what the rule permits;
 * naming one vendor while describing a mechanism any agent could serve is what
 * it forbids, and moving the name out of the copy and into the catalogue is how
 * this file stops doing the second one.
 *
 * ## Null is a real answer
 *
 * `shell` has no binary — `bin` is null in its row, because a login shell is
 * `$SHELL` or `%COMSPEC%` and is resolved at spawn rather than looked up — and
 * an unknown id has no row at all. Both mean there is genuinely nothing to
 * start, and the caller draws no button rather than one that would type an
 * empty line into somebody's terminal. A person whose default *is* the plain
 * shell has asked for a terminal and nothing else; offering to start an agent
 * they did not pick would be guessing on their behalf.
 */
export function runnableAgent(provider: ProviderId | null | undefined): AgentEntry | null {
  if (provider == null) return null
  const entry = AGENT_CATALOG[provider] as AgentEntry | undefined
  return entry?.bin == null ? null : entry
}

/**
 * What the Run button types, for that agent.
 *
 * The bare command with the agent's own start arguments, and nothing else. Not
 * `resumeArgs`: those silently resume whichever conversation was last written
 * in the folder, which is a different thing from what the button says and — as
 * `session-transcript.ts` records at length — is frequently not this session's
 * conversation at all.
 *
 * `\r`, not `\n`: a pty carries what a keyboard sends, and Return is carriage
 * return. The rest of this app types into sessions the same way — see
 * `sendCommand` in `main/agent-controls.ts`.
 */
export function runAgentCommand(entry: AgentEntry): string {
  return `${[entry.bin, ...entry.args].join(' ')}\r`
}

/**
 * What the menu is called: one word, and the same word in both modes.
 *
 * It read `Start a session as` / `Run this session as`, and the second is the
 * phrasing he rejected outright:
 *
 *   > *"So run them as is not the best way. Maybe you can say primary account,
 *   > choose primary account or this kind of words, or default account. That
 *   > will be the better words instead of run them as."*
 *
 * He was standing on the settings row when he said it, and that row is now
 * **Primary account** — but the words he rejected were not one label, they were
 * a phrasing, and it was also the head of this menu and the title of the sheet
 * this menu opens. `Primary account` cannot be borrowed here: the primary
 * account is a machine-wide default, and this menu is about *one session*, so
 * the two would be one name over two different facts. The noun on its own is
 * what both modes are actually about, and the rows underneath already say what
 * pressing one does.
 *
 * Still declared once and read by the heading and the `aria-label` together,
 * because those two must never say different things.
 */
export const MENU_HEAD = {
  start: 'Account',
  switch: 'Account',
} as const

/**
 * Why picking a row will not change the session in front of you, when it will
 * not — and what it does instead.
 *
 * ## The state this exists for
 *
 * `switching` below needs the session's *own* account off `SessionMeta`, and the
 * commonest session this app has does not have one. An agent started by pressing
 * Run Claude, or by typing `claude` at a shell prompt, runs inside a pty this app
 * spawned as `$SHELL -l` — `supportsProfiles('shell')` is false, so no config
 * directory was ever handed to it and `SessionMeta` carries no account. The main
 * process refuses to switch such a session for exactly that reason, in
 * `switchRefusal`, and it is right to: the replacement would be another shell,
 * and `sessionEnv(profile, 'shell')` exports nothing, so the "switch" would move
 * the label and not the login.
 *
 * So the menu silently fell back to its other mode. Same heading — `MENU_HEAD`
 * is deliberately one word for both — same rows, same tick on the account this
 * session really is running as, and a press that opened *a second session* while
 * the one in front of you carried on under the old login, still printing that
 * login's limit warnings into its own terminal. Asad, on the account surfaces
 * disagreeing:
 *
 *   > *"after we switch it shows something else … all of them are not about one
 *   > logged in account, they are talking about different account."*
 *
 * ## Why this is a sentence and not a repair
 *
 * Because the restriction is real. A process's environment cannot be rewritten
 * after it starts — the argument is at the top of this file — and this app never
 * handed this one an account to begin with, so there is nothing for it to
 * restart *as*. The honest thing is to say so where the choice is made, rather
 * than to leave a menu whose two modes look identical and do different things.
 *
 * Behind the same dot `foreign` uses, which is the control he asked for when he
 * asked for the paragraphs to go — *"give the i icon like other ones"* — and the
 * two are mutually exclusive, so the heading never grows two.
 */
export const FIXED_ACCOUNT_NOTE = {
  /**
   * An agent somebody typed into a shell — Run Claude, or `claude` at the
   * prompt. The pty is `$SHELL -l`, so no configuration directory was ever
   * exported into it and there is nothing for a replacement to be started *as*.
   */
  shell:
    'The agent here was started inside a shell, so this app never handed it an account and cannot restart it as another one. Picking an account opens a new session on it, and this one keeps the login it has.',
  /**
   * An agent this app *did* spawn, whose login it cannot keep apart from the
   * machine's — Gemini, and every agent somebody added. `supportsProfiles` is
   * the authority and `provider-accounts.ts` records why for each of them.
   */
  agent:
    'This app cannot give this agent an account of its own, so this session cannot be restarted as another one. Picking an account opens a new session on it, and this one keeps the login it has.',
} as const

/**
 * That sentence, or null — pure, so it can be pinned without a DOM.
 *
 * `sessionAgent` is the session's own account's agent, off `SessionMeta`, and
 * null is the whole of what this is about: no account was attached at spawn.
 * Two ways that happens and they are two different facts, so they get two
 * sentences — `sessionProvider` tells them apart. A caller that simply passed no
 * `onSwitchAccount` is a third absence and gets nothing, because "this app
 * cannot" would then be a claim about the caller rather than about the session.
 */
export function fixedAccountNote(input: {
  /** Is the chip drawn over a session at all? */
  hasSession: boolean
  /** Is an agent running in it — `chipMode` answering `account`? */
  showAccount: boolean
  /** Would a row switch this session? */
  switching: boolean
  sessionAgent: ProviderId | null
  /** What this app launched, off `ChromeSession`. */
  sessionProvider: ProviderId | null
}): string | null {
  if (!input.hasSession || !input.showAccount || input.switching) return null
  if (input.sessionAgent !== null) return null
  return input.sessionProvider === 'shell' ? FIXED_ACCOUNT_NOTE.shell : FIXED_ACCOUNT_NOTE.agent
}

/** The row being renamed, and what has been typed into it so far. */
interface Editing {
  id: string
  draft: string
}

/**
 * The agent's name for a screen reader, or undefined when there is no mark.
 *
 * Undefined is what puts `ProviderBadge` into its decorative mode, which is
 * right in both cases that produce it: no agent known, so nothing is drawn, so
 * there is nothing to announce.
 */
function agentLabel(provider: ProviderId | null | undefined): string | undefined {
  return provider == null ? undefined : providerOption(provider)?.label
}

export function AccountChip({
  current,
  pendingAccount = null,
  projectPath,
  provider,
  session = null,
  onRunAgent,
  onPick,
  onSwitchAccount,
  onManage,
}: Props) {
  const agent = useAgentPresence(session)
  /*
   * Which login the agent in *this* session is on, as the main process
   * established it — from its own spawn record where it started the session, and
   * from the agent process's own environment where it did not.
   *
   * This is the fix. See `established` below for what it replaced and why the
   * thing it replaced was a claim the app could not support.
   */
  const established = useSessionAccount(session?.id ?? null, agent.running)
  /** Whether the previous render drew the Run button. See `revealing`. */
  const wasRun = useRef(false)
  const [editing, setEditing] = useState<Editing | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  // Escape belongs to the field while one is open — see `useChipMenu`.
  const menu = useChipMenu(null, editing !== null)
  /*
   * Non-null exactly when a new session here would run an agent that has no
   * account to be given. The rows below stop being buttons when it is set.
   */
  const blocked = isolationNotice(provider)
  /*
   * The list always; the sign-in probes only while the menu is open.
   *
   * The probes are the expensive half — one spawn of the agent's CLI per
   * account — and running them on mount would cost three processes every time a
   * tab changed. The *list* is a JSON file read, and gating it behind the menu
   * was a mistake with a visible symptom: until you had opened the menu once,
   * the chip did not know which account a new session here would use, could not
   * colour its dot, and could not tell a generated name from one you chose.
   */
  const accounts = useAccounts(true, menu.open)

  const rows: readonly AccountView[] = accounts.snapshot.accounts

  /**
   * Save the name being edited, then re-read the list.
   *
   * The re-read is the reason this does not just patch the row: ids, colours
   * and config directories are the main process's to assign, and a name written
   * only into local state is a row that no longer matches the account on disk.
   */
  const save = (account: AccountView): void => {
    const typed = editing?.draft ?? ''
    setSaving(true)
    setFailure(null)
    void renameAccount(accountsBridge(), account, typed).then((problem) => {
      setSaving(false)
      setFailure(problem)
      // A failed rename keeps the field open with what was typed still in it —
      // closing it would throw the name away along with the message explaining
      // why it did not take.
      if (!problem) {
        setEditing(null)
        accounts.reload()
        // And the Settings pane, and every other session's chip: one rename,
        // one list, wherever it is drawn. See `announceAccountsChanged`.
        announceAccountsChanged()
      }
    })
  }

  /*
   * What the button says, and which row is marked as the one in use.
   *
   * The running session's own account when it has one, because that is a fact
   * about what is on screen and stays true even if the account has since been
   * removed from the list. Otherwise the account a new session in this folder
   * *would* use, resolved the way the main process resolves it.
   *
   * The colour is looked up separately and on purpose: a session can name an
   * account that is no longer in the list, and inventing a colour for it would
   * put a coloured dot beside a name that matches no row in the menu.
   */
  /*
   * The folder's default account — **only** when there is no session.
   *
   * This one line is the reported bug. `accountForFolder` answers "which account
   * would a new session started here use", which is a true and useful answer to
   * a question nobody is asking while a session is on screen, and it was being
   * printed as that session's account whenever the session had no profile of its
   * own — every plain shell with an agent typed into it, which is most of them.
   * Asad, twice, the second time pointing at a local session:
   *
   *   > "here it is showing actually the wrong account — app.imatch.ae is not
   *   > the correct account which is connected to this session … this is your
   *   > terminal account which is becoming visible here"
   *
   * Over a session the account now comes from {@link established} or from
   * nowhere. There is no rung between them, because every candidate for one is a
   * fact about something other than this session.
   */
  const fallback = session ? null : accountForFolder(accounts.snapshot, projectPath)

  /**
   * The session's own account, and the sentence when there is none to name.
   *
   * `current` — the profile off `SessionMeta` — is not consulted separately: it
   * *is* the first rung of what the main process answered, so preferring it here
   * would be the same fact read from a staler copy. It is still used below for
   * the questions that really are about the spawn, such as whether this session
   * can be switched to another account at all.
   */
  const known = established?.kind === 'known' ? established : null
  const withheld = established?.kind === 'withheld' ? established.reason : null
  /*
   * An account this app has no record of is still an account, and is named by
   * the address signed into it rather than by its path. That is the case a
   * `CLAUDE_CONFIG_DIR` exported in somebody's shell profile produces, and it is
   * exactly the case that used to read as the default login.
   */
  const sessionAccount =
    known === null
      ? null
      : {
          id: known.profileId ?? known.configDir,
          name: known.profileName ?? known.email ?? known.configDir,
          provider: known.provider,
        }

  /**
   * The account this chip names, in the order the answers can be trusted.
   *
   * `sessionAccount` is the established one and outranks everything. `current`
   * behind it is not a second guess: it is this app's own spawn record off
   * `SessionMeta`, which is the *same* fact the main process's first rung
   * returns, and it is the only one available to the two callers that pass an
   * account without passing a `session` to go with it. `fallback` is last and,
   * by the line above, exists only when there is no session to be wrong about.
   */
  const namedAccount = sessionAccount ?? current ?? null
  const currentId = namedAccount?.id ?? fallback?.id ?? null
  const listed = currentId === null ? null : rows.find((row) => row.id === currentId) ?? null

  /**
   * The account this chip is about, as a record the identity ladder can read.
   *
   * The name is taken from the *list* first and from the session second. Both
   * are true statements about different moments — the session's copy was
   * written at spawn — and a rename lands in the list, so preferring the
   * session's would leave the chip showing the old name until the session ended.
   *
   * Not called `account`: the rows below are mapped over a parameter of that
   * name, and one of them being the whole chip's subject while the other is
   * whichever row is being drawn is a shadow nobody should have to hold in
   * their head while reading a menu.
   */
  const currentAccount =
    currentId === null
      ? null
      : {
          id: currentId,
          name: listed?.name ?? namedAccount?.name ?? fallback?.name ?? currentId,
          system: listed?.system,
        }

  /*
   * Who this session is running as.
   *
   * Two sources, and the order matters. While the menu is open the whole list
   * has been probed, so `accounts.signIn` holds the freshest answer for every
   * row and the chip must agree with the row the tick is on. The rest of the
   * time — which is nearly all of it — that map is empty and the single-account
   * probe is the only thing that knows.
   */
  /*
   * Not probed for a directory this app has no account record of.
   *
   * `profileSignIn` is keyed on a profile id and answers by starting the agent's
   * own CLI — ~245 ms — so asking it about a bare path costs a process to be
   * told nothing. The address for that case has already been read off the file
   * the CLI wrote, and is the account's `name` above.
   */
  const identityId = known !== null && known.profileId === null ? null : currentId
  const probed = useAccountIdentity(identityId)
  const currentSignIn = (identityId === null ? undefined : accounts.signIn[identityId]) ?? probed
  const identity = accountIdentity(currentAccount, currentSignIn)

  /**
   * The account's name, for the tooltip, when the name is worth saying.
   *
   * Only a name a person chose. The generated one — "Default", "Default (Codex
   * CLI)" — is exactly the string this whole change is about getting off the
   * chip, and putting it back on hover would be the same claim in smaller type;
   * it says nothing the provider badge does not already say. Dropped too when
   * it is already the label, which is the ordinary case for a chosen name whose
   * agent has not reported an address.
   */
  const chosen =
    currentAccount !== null &&
    !(currentAccount.system ?? isSystemAccountId(currentAccount.id))
      ? currentAccount.name
      : null
  const chosenName = chosen === identity.label ? null : chosen

  /**
   * Whether this chip has an account to name at all.
   *
   * Two subjects, and until now the chip could show one while explaining the
   * other. With an account of its own — `current`, the account the session on
   * screen was actually spawned under — it describes that session, and it stays
   * true whatever the app's *default* agent has since been set to. With none, it
   * describes what a new session here would use, which is a claim about the
   * agent in `provider`, and `blocked` is precisely the answer "that agent
   * cannot be given an account".
   *
   * Both halves were being drawn at once. Reported from one frame: a chip
   * reading `Claude Code · Work` whose own tooltip read *"A plain shell has no
   * account to sign in to"*, over a session whose chat body said *"This session
   * is a shell"* — three statements, two of them contradicting the third. The
   * label and the mark came from `accountForFolder`, which resolves the folder's
   * default account regardless of whether anything could be handed it, while the
   * tooltip came from the notice. Neither was wrong on its own terms; they were
   * answering different questions in one control.
   *
   * So when there is no session account *and* nothing could be given one, the
   * chip names nobody. The menu still opens — the accounts are still worth
   * seeing, and Add or sign in is still the way to another one — and the notice
   * inside it says why the rows are inert.
   */
  const names =
    session !== null ? namedAccount !== null : current !== null || blocked === null

  /**
   * What stands where the name would be when there is none, and why.
   *
   * Three states, and collapsing any two of them puts a claim on the chip that
   * is not true of the session under it:
   *
   *  - **Account not known.** The main process looked and could not establish
   *    it — a session started outside the app whose agent process would not give
   *    up its environment, or one on a platform where that cannot be asked. This
   *    is the state this whole change exists to produce, and it is *useful*: it
   *    says the app is not naming anybody rather than naming the wrong person.
   *  - **Checking…** Nothing has answered yet. Not the same as the above by any
   *    means — the answer is a few milliseconds away — and drawing the refusal
   *    here would flash a permanent-sounding sentence on every tab change.
   *  - **No login.** There is no session, and the agent a new one here would run
   *    cannot be given an account at all. The words are `signInStateSummary`'s
   *    for the same situation, reused so the chip and the menu row do not read as
   *    two different findings.
   */
  const unnamed: { label: string; detail: string | null } =
    withheld !== null
      ? { label: 'Account not known', detail: withheld }
      : session !== null && established === undefined
        ? {
            label: 'Checking…',
            detail: 'Reading which account the agent in this session is running as.',
          }
        : { label: 'No login', detail: blocked }

  /**
   * Which agent's mark goes on the button, in three fallbacks that are three
   * different facts rather than three guesses at one.
   *
   * The running session's own agent first: that is what was actually launched,
   * and it stays true even for an account that has since been removed from the
   * list. Then the listed account's, which is only available once the menu has
   * been opened at least once and the list has been read. Then — for a chip
   * that is describing what a *new* session here would use — the agent that new
   * session would run, because the account is resolved against it.
   *
   * Undefined when the chip names nobody, and that is the case worth spelling
   * out: the agent it would otherwise name is one that cannot take an account at
   * all, so a mark beside an account name would be claiming exactly the pairing
   * the notice underneath says is impossible. The check is `names` rather than
   * `blocked` because a *session's* account outranks it — a Claude session keeps
   * its Anthropic mark while the default coding tool is a plain shell, which is
   * a setting about the next session and not about this one.
   */
  const mark = names ? namedAccount?.provider ?? listed?.provider ?? provider : undefined

  /**
   * The agent the Run button would start, and the whole of what it names.
   *
   * `provider` is the setting `newSessionIn` sends — the agent a session
   * started from this spot would run — so the button offers the *same* agent
   * the `+` beside it would, rather than a second opinion about which one this
   * person uses. See {@link runnableAgent} for why null is a real answer and
   * what the caller does with it.
   */
  const startable = runnableAgent(provider)

  /**
   * Start that agent in this session.
   *
   * Re-checked at the moment of the press, not only at the moment the button
   * was drawn. The presence reading is a screen reading and a screen can change
   * between those two instants — an agent started from the terminal a second
   * ago, say — and the cost of being late is not a no-op: the command typed at
   * an agent that is already running is submitted to it as a prompt.
   *
   * `startable` is re-checked here as well, and not out of caution: this
   * closure is handed to an element that only exists when it is non-null, but a
   * handler that would send `null ` into somebody's terminal if that ever
   * stopped being true is a handler one refactor away from doing it.
   */
  const runAgent = (): void => {
    if (!session || agent.running !== false || startable === null) return
    if (onRunAgent) {
      onRunAgent(session.id)
      return
    }
    const deck = (globalThis as { deck?: { writeToSession?: (id: string, data: string) => void } }).deck
    deck?.writeToSession?.(session.id, runAgentCommand(startable))
  }

  /*
   * A session with no agent in it wears no agent's controls.
   *
   * Three states, not two, because `running` has three values:
   *
   *   false → the screen was read and there is no agent. Offer to start one.
   *   true  → there is one. The account picker, exactly as before.
   *   null  → nothing has been read yet. Neither, and this is the interesting
   *           one: guessing "no agent" here would put a Run button in front of
   *           a running agent, and pressing it submits the command as a prompt.
   *           Guessing "agent" would put the account picker back on a plain
   *           shell, which is the complaint itself.
   *
   * `null` resolves within a few hundred milliseconds of the session printing
   * anything, and stays for good in a build with no controls channel — where
   * showing no control at all is the honest answer, and the folder chip beside
   * it still is one.
   */
  const mode = chipMode(session, agent)
  const showRun = mode === 'run'
  const showAccount = mode === 'account'
  /**
   * Whether picking a row switches this session or starts another one.
   *
   * Four conditions, and each rules out a case where switching would be a
   * promise rather than a fact:
   *
   *  - a session on screen, because there is otherwise nothing to switch;
   *  - a handler, because a caller that did not pass one has not built the other
   *    half and a row that called nothing would be the dead control the design
   *    brief forbids;
   *  - an agent actually running in it — `mode === 'account'` — because stopping
   *    a plain shell and starting an agent in its place is not "the same session
   *    under another login", it is a different thing wearing the same words;
   *  - **and the session's own account and agent**, both of which come off
   *    `SessionMeta` at spawn. Without them this cannot say which accounts are
   *    even eligible, and a menu that offers every row and lets the main process
   *    refuse most of them is the silent no-op this chip has already been
   *    reported for once.
   */
  const sessionAgent = current?.provider ?? null
  const switching =
    session !== null && onSwitchAccount !== undefined && showAccount && sessionAgent !== null
  /*
   * Rows this session cannot be run as, because they are logins of another
   * agent. Counted rather than described per row: the reason is the same
   * sentence for every one of them, and repeating it down a list of three is
   * noise where one line above them is an explanation.
   */
  const foreign = switching && rows.some((row) => row.provider !== sessionAgent)
  /*
   * And the other half of the same question: this menu is over a live agent and
   * a row will *not* switch it. See {@link FIXED_ACCOUNT_NOTE} — this is the
   * state that made the account chip, the usage bar and the session's own limit
   * warnings look like three claims about three different logins.
   */
  const fixed = fixedAccountNote({
    hasSession: session !== null,
    showAccount,
    switching,
    sessionAgent,
    sessionProvider: session?.provider ?? null,
  })
  /*
   * Was the account picker away a moment ago?
   *
   * The swap is between two different elements, so there is nothing for a CSS
   * transition to interpolate — the picker would simply appear. He asked for
   * the pill to *expand* to reveal it, so it is animated in, and only on the
   * render where it takes the other state's place. Animating it on every mount
   * would replay the same flourish on every tab switch, which is the difference
   * between a transition and a tic.
   */
  const revealing = wasRun.current && showAccount
  wasRun.current = !showAccount

  /*
   * Nothing to draw, in three different ways.
   *
   * `!showAccount && !showRun` is the presence reading not having arrived. The
   * third is the one added when the button stopped naming one fixed agent: this
   * slot is in Run mode — a live shell with nothing running in it — and the
   * person's default is the plain shell, so there is no agent to offer.
   *
   * It has to fall out here rather than dropping through, and the drop-through
   * is a bug this actually shipped for a few minutes: the code below would have
   * put the **account picker** back on a plain shell, which is the whole of the
   * complaint the Run button was built to answer —
   *
   *   > "Starting a session gives you a plain shell. Today that shell still
   *   > shows the chat/terminal switch and the account dropdown — both of which
   *   > mean nothing until an agent is running in it."
   *
   * — and it read, on screen, "No login ⌄". Drawing neither control is the only
   * honest state: the brief's rule for a control that cannot act is that it is
   * removed rather than shown inert, and an inert Run button would have nothing
   * true to put in its tooltip either, because the reason is not "this failed"
   * but "you did not ask for an agent".
   */
  if (!showAccount && !showRun) return null
  if (showRun && startable === null) return null

  /*
   * `session &&` as well as `showRun`, so the branch narrows. `chipMode` only
   * answers `run` for a session, but that is a fact about another module and
   * the compiler is right not to take it on trust.
   */
  if (showRun && session && startable !== null) {
    return (
      <div className="account-chip account-chip-run">
        <button
          type="button"
          className="folder-chip-button run-agent-button"
          /*
           * Both sentences name the agent from its own catalogue row, for the
           * reason set out on {@link runnableAgent}: the label, the tooltip and
           * the keystrokes are three statements about one thing, and reading
           * all three off `startable` is what stops any of them drifting into
           * describing an agent this session is not about to run.
           */
          title={
            session.exited
              ? 'This session has ended — nothing can be started in it'
              : `Start ${startable.label} in this session. Types the command for you, in this terminal.`
          }
          disabled={session.exited}
          onClick={runAgent}
        >
          {/* The same glyph the terminal draws for a prompt — this button is
              standing in for typing at one. */}
          <span className="run-agent-glyph" aria-hidden="true">
            ❯
          </span>
          <span>Run {startable.label}</span>
        </button>
      </div>
    )
  }

  return (
    <div
      className={revealing ? 'account-chip is-revealing' : 'account-chip'}
      ref={menu.hostRef}
    >
      <button
        type="button"
        className="folder-chip-button account-chip-button"
        aria-haspopup="menu"
        aria-expanded={menu.open}
        /*
         * Everything the label had to leave out.
         *
         * The label is one short line and is now the *identity* rather than the
         * record, so the account's own name — which is genuinely useful when it
         * is a word somebody chose, and is the thing being renamed a few pixels
         * below — has nowhere else to be. The last sentence is the agent's own,
         * naming the command it came from; that is what makes the line above it
         * something a person can check rather than something they must believe.
         */
        title={
          !names
            ? /*
               * Nothing is named, so the sentence saying why is the whole of what
               * there is to say — and now it is the only thing the chip is
               * claiming, rather than a contradiction of the name printed beside
               * it.
               *
               * The session's own reason first, because it is about the thing on
               * screen: *this* session's account could not be established. The
               * notice is about a different session — the one a row would start —
               * and only stands when there is no session here at all.
               */
              (unnamed.detail ?? undefined)
            : [
                /*
                 * Three sentences for three genuinely different offers, and the
                 * wording of each has to be the thing that actually happens.
                 *
                 * With a switch available it is *this* session that moves — the
                 * process is stopped and started again under the other account,
                 * in the same tab. Without one, the old sentence still stands
                 * and still has to: a running agent cannot change account, so
                 * the only thing a click can do there is start another session,
                 * and promising a switch this caller cannot perform would be
                 * the control lying about itself.
                 */
                switching
                  ? 'This session is running as this account — pick another to run this session as instead.'
                  : namedAccount
                    ? 'This session is running as this account — start one under a different account.'
                    : 'A new session here would use this account.',
                chosenName === null ? null : `Account: ${chosenName}.`,
                identity.detail,
                /*
                 * And nothing about `blocked` here, deliberately. When this
                 * chip is naming a session's own account, the notice is about a
                 * *different* session — the one that would start if you picked
                 * a row — and a sentence about another session inside a tooltip
                 * describing this one is how the two subjects got mixed up in
                 * the first place. The menu says it, at the moment the rows
                 * that cannot be picked are actually on screen.
                 */
              ]
                .filter((line) => line !== null)
                .join(' ')
        }
        onClick={menu.toggle}
      >
        {/* The colour belongs to an account, so it is only painted while one is
            being named. Left on, it put the folder's default account's colour
            beside a chip that has just said there is no login to speak of. */}
        <span
          className="account-chip-dot"
          aria-hidden="true"
          style={names && listed ? { background: `var(${listed.color})` } : undefined}
        />
        {/* The dot says which account; this says which agent. Both are needed:
            the dot is a colour assigned round-robin and means nothing on its
            own, and the name is a word somebody typed. Announced, because
            nothing else in the chip names the agent. */}
        <ProviderBadge provider={mark} size={13} label={agentLabel(mark)} />
        {/* `data-verified` is set only for an address the agent's own CLI
            named. The stylesheet leans on it to draw a read fact at full
            strength and an app-composed state — "Checking…", "Not signed in" —
            one step back, so the two can never be mistaken for each other. */}
        <span className="account-chip-name" data-verified={(names && identity.verified) || undefined}>
          {/* "No login" is the word this app already uses for an agent that has
              none to give — `signInStateSummary`'s `unsupported` rung says the
              same thing about an account whose CLI cannot be signed into. Reused
              rather than reworded so the chip and the menu row for the same
              situation do not read as two different findings. */}
          {names ? identity.label : unnamed.label}
        </span>
        {/* The armed switch, if there is one. Written as an arrow into the
            waiting account rather than as a badge saying "pending", because the
            question somebody has is *which* account and *when* — the arrow
            answers the first and the title answers the second. Announced
            politely: it changes without anybody touching the chip, and a bare
            alert every time one is armed would interrupt the terminal it sits
            above. */}
        {pendingAccount !== null && (
          <span
            className="account-chip-pending"
            title={`Switching to ${pendingAccount} when you send your next message.`}
          >
            → {pendingAccount}
          </span>
        )}
        <svg
          width="14"
          height="14"
          viewBox="0 0 20 20"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={CHEVRON} />
        </svg>
      </button>

      {menu.open &&
        createPortal(
          <div
            ref={menu.menuRef}
            className="folder-menu"
            role="menu"
            /* The heading and the label are one string on purpose: the menu is
               announced by the same words it is titled with, and the two modes
               are two different promises — "run the session in front of you as"
               is not "open a new one as", and a screen reader hearing the wrong
               one has been told the wrong thing about what a press will do. */
            aria-label={MENU_HEAD[switching ? 'switch' : 'start']}
            style={{ left: menu.at.left, top: menu.at.top }}
          >
            <p className="folder-menu-head">
              {MENU_HEAD[switching ? 'switch' : 'start']}
              {/*
                Why some rows below cannot be picked — behind the dot, not over
                them.

                It was a sentence at the top of the menu: *"Only a Claude Code
                account can run this session — an account is a login of one
                agent."* True, and printed every single time this menu was
                opened on a machine with more than one agent installed, which is
                every machine this app is for. *"Don't put any single statement
                in anywhere… if somewhere it's very required, give the i icon
                like other ones."* The rows it is about are already visibly not
                buttons; this is the answer for somebody who wants to know why.
              */}
              {foreign && (
                <HoverNote label="Which accounts can run this session">
                  {`Only a ${agentLabel(sessionAgent) ?? 'matching'} account can run this session — an account is a login of one agent.`}
                </HoverNote>
              )}
              {/* Mutually exclusive with the one above — `foreign` requires
                  `switching` and this requires its absence — so the heading
                  never carries two dots. */}
              {fixed !== null && (
                <HoverNote label="What picking an account does here">{fixed}</HoverNote>
              )}
            </p>

            {/* Why the rows below cannot be picked, before they are read rather
                than after one is clicked.

                `blocked` is a statement about the agent a *new* session here
                would run, so it has nothing to say while these rows are about
                switching the session already on screen — that session's agent
                is running, and is by definition one that takes an account.
                Printed in switch mode it would be a sentence about a different
                session, which is exactly the two-subjects-one-control fault
                `names` exists to prevent, one level down. */}
            {!switching && blocked && <p className="account-menu-blocked">{blocked}</p>}

            {rows.map((account) => {
              const state = accounts.signIn[account.id]
              /*
               * The tick follows the button. A chip that has just said there is
               * no login to speak of must not then mark one of these rows as
               * the one in force — that is the same contradiction one level
               * down, and the tick is the strongest claim in the menu.
               */
              const isCurrent = names && account.id === currentId
              /*
               * What this row is called on screen, and therefore what every
               * control on it is called to a screen reader.
               *
               * The rename affordances used to name `account.name`, which is
               * the stored name and — for the machine's own install — the
               * generated key: a row reading `app.imatch.ae@gmail.com` with a
               * button announced as "Rename Default". The field itself still
               * holds the stored name, because that is the string being
               * edited; what is *announced* is the row you are on.
               */
              const login = profileLoginLabel(account, state)

              /*
               * Renaming in place, in the row the name is already on.
               *
               * A form, so Return submits without a button of its own — the
               * whole row is 300px wide and a Save button beside a field that
               * accepts Return would be the third control on one line.
               */
              if (editing?.id === account.id) {
                return (
                  <div key={account.id} className="account-menu-editing">
                    <form
                      className="folder-menu-item account-menu-item account-menu-rename"
                      onSubmit={(event) => {
                        event.preventDefault()
                        save(account)
                      }}
                    >
                      <span
                        className="account-chip-dot"
                        aria-hidden="true"
                        style={{ background: `var(${account.color})` }}
                      />
                      <input
                        className="account-menu-input"
                        value={editing.draft}
                        maxLength={MAX_ACCOUNT_NAME_LENGTH}
                        autoFocus
                        disabled={saving}
                        aria-label={`New name for ${login}`}
                        aria-invalid={failure !== null || undefined}
                        aria-describedby={failure === null ? undefined : 'account-rename-problem'}
                        onChange={(event) => setEditing({ id: account.id, draft: event.target.value })}
                        onKeyDown={(event) => {
                          // The menu is holding Escape open for exactly this.
                          if (event.key !== 'Escape') return
                          event.preventDefault()
                          setEditing(null)
                          setFailure(null)
                        }}
                      />
                    </form>
                    {/*
                      Why the name did not take, under the field it was typed
                      into.

                      A rename can collide — the main process refuses two
                      accounts of one agent with the same name — and the only
                      thing that reaches the renderer for that is a rejected
                      `invoke`, whose message arrives wrapped as `Error invoking
                      remote method 'profiles:rename': ProfileError: …`. That
                      string names a channel nobody using this app has heard of.
                      `errorMessage` in `accounts.ts` takes the sentence off the
                      end of it; this puts that sentence where the correction
                      has to be made, rather than at the bottom of a list of
                      other people's accounts where it used to sit.
                    */}
                    {failure && (
                      <p id="account-rename-problem" className="account-menu-problem" role="alert">
                        {failure}
                      </p>
                    )}
                  </div>
                )
              }

              const line = (
                <>
                  {/* The whole login, because the name is ellipsised when the row
                      runs out of room — see `.account-menu-line > .folder-menu-name`
                      in `shell.css`. A cut address with no way to read the rest
                      is a picker you cannot pick from. */}
                  <span className="account-menu-line" title={login}>
                    {/* The one in force. A fixed slot whether it is drawn or
                        not, so the names below it stay in one column — a tick
                        that shunts its own row 14px right turns a scannable
                        list into a ragged one. Inside this span rather than
                        beside it, because the row is `space-between` and a
                        third child would be pushed to the middle of it. */}
                    <span className="account-menu-tick" aria-hidden="true">
                      {isCurrent && (
                        <svg
                          width="14"
                          height="14"
                          viewBox="0 0 20 20"
                          fill="none"
                          stroke="currentColor"
                          strokeWidth="2"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        >
                          <path d={TICK} />
                        </svg>
                      )}
                    </span>
                    <span
                      className="account-chip-dot"
                      aria-hidden="true"
                      style={{ background: `var(${account.color})` }}
                    />
                    {/* Which agent this row would start. Two accounts can
                        legitimately share a name across agents — the main
                        process only refuses a duplicate *within* one — so
                        without this the list can hold two rows reading "Work"
                        that start different CLIs. */}
                    <ProviderBadge provider={account.provider} label={agentLabel(account.provider)} />
                    {/* The login, not the key it is filed under. These rows
                        printed `account.name`, so a menu opened from a chip
                        reading `app.imatch.ae@gmail.com` offered a row reading
                        `Default` — the same account, two names, one frame.
                        `profileLoginLabel` is the ladder the pickers use, and
                        the probe it reads has already run: this menu asks about
                        every account the moment it is opened. */}
                    <span className="folder-menu-name">{login}</span>
                  </span>
                  {/* Read, not assumed. An account the agent has not answered
                      about yet says so, and one it could not answer about says
                      that instead of a cross.

                      `signInStateSummary` is `signInSummary` with its address
                      rung removed, and the removal is what keeps this column
                      saying anything at all: the left of the row now prints the
                      address off that same ladder, so both halves resolved to
                      the identical string and the row said one fact twice while
                      the state — whether this account can start a session —
                      went unsaid. The two are one ladder with one entry point
                      each, so they cannot drift apart. */}
                  <span className="account-menu-state" data-state={state?.state ?? 'unknown'}>
                    {signInStateSummary(state).label}
                  </span>
                </>
              )

              /*
               * Whether this row can be acted on at all, and there are now
               * three quite different reasons it might not be.
               *
               * Starting: the agent a new session here would run cannot be
               * handed a config directory, so no row means anything — `blocked`
               * holds that, and the notice above the list says it.
               *
               * Switching: a row is a login of another agent, and an account
               * only means something to the agent it is a login of; or it is the
               * account this session is *already* running as, where the tick has
               * already said everything there is to say and a press could only
               * stop a healthy agent and start it again as itself.
               *
               * And — new, 2026-08-20 — switching *into an account that has
               * never signed in*. That switch does not fail; it succeeds, and
               * what appears is the CLI's own first-run onboarding followed by
               * a login prompt, with the conversation he was reading gone off
               * the screen. On screen it is indistinguishable from the defect he
               * filmed:
               *
               *   > *"See, it is not going to keep it… It's not keeping the
               *   > conversation history."*
               *
               * There is nothing to resume into an account with no login, so the
               * only outcome a press here can have is losing what is on screen.
               * The row stays listed, because it is a real account and it is
               * what **Sign in** in Settings is for; it just is not a thing this
               * session can be handed to. No sentence is added for it: the right
               * of the row already reads *Not signed in*, which is the whole
               * reason, in two words that were already there.
               *
               * Only a measured `signed-out` counts. `unknown` is a probe that
               * could not be run — an old CLI, a timeout — and refusing on that
               * would block a perfectly good account over a failure to ask.
               */
              const inert = switching
                ? account.provider !== sessionAgent ||
                  isCurrent ||
                  state?.state === 'signed-out'
                : blocked !== null

              /*
               * A paragraph, not a disabled button. The accounts are still worth
               * showing — they are what the Accounts screen would let you sign
               * in to — but nothing here can act on them, and a button that
               * cannot be pressed still looks like the app's answer to the
               * question.
               *
               * Rename stays available either way. Whether this agent can be
               * given a config directory, or whether this login can run the
               * session in front of you, has nothing to do with whether the
               * account's *name* is right, and the name is what is on screen.
               */
              return (
                <div key={account.id} className="account-menu-row">
                  {inert ? (
                    /* `data-current` here too. A row is inert for reasons that
                       have nothing to do with which account the session on
                       screen is running as — and that was the state the mark
                       disappeared in, i.e. the state where the question is
                       hardest. */
                    <p
                      className="folder-menu-item account-menu-item is-inert"
                      data-current={isCurrent || undefined}
                      aria-current={isCurrent || undefined}
                    >
                      {line}
                    </p>
                  ) : (
                    <button
                      type="button"
                      /*
                       * `menuitemradio`, not `menuitem`. These rows are a choice
                       * of exactly one account and one of them is already in
                       * force; `aria-checked` is how that is said out loud, and
                       * without it the tick is a mark only a sighted user gets.
                       */
                      role="menuitemradio"
                      aria-checked={isCurrent}
                      className="folder-menu-item account-menu-item"
                      data-current={isCurrent || undefined}
                      onClick={() =>
                        menu.choose(() =>
                          /*
                           * The one place the two modes diverge in what a press
                           * *does*. `switching` already required both a session
                           * and a handler, so the narrowing here is the
                           * compiler's business rather than a second check —
                           * but it is spelled out because a row that silently
                           * fell through to `onPick` would open a second
                           * session in the same folder, which is the exact
                           * behaviour this whole change exists to remove.
                           */
                          switching && session && onSwitchAccount
                            ? onSwitchAccount(session.id, account.id)
                            : onPick(account.id, account.provider ?? undefined),
                        )
                      }
                    >
                      {line}
                    </button>
                  )}
                  <button
                    type="button"
                    className="account-menu-rename-button"
                    title={`Rename ${login}`}
                    aria-label={`Rename ${login}`}
                    onClick={() => {
                      setFailure(null)
                      setEditing({ id: account.id, draft: account.name })
                    }}
                  >
                    Rename
                  </button>
                </div>
              )
            })}

            {/*
              A rename that failed with no field left open.

              Only reachable if the row being edited leaves the list between the
              submit and the reply — the account was deleted from the Accounts
              screen in another window, say. The message is still worth printing:
              it says what went wrong, and the alternative is a rename that
              silently did not happen. The ordinary case is handled beside the
              field itself, above.
            */}
            {failure && editing === null && <p className="account-menu-problem">{failure}</p>}

            {rows.length === 0 && (
              <p className="account-menu-empty">
                {accounts.loading ? 'Reading your accounts…' : 'No accounts to choose from.'}
              </p>
            )}

            {accounts.error && <p className="account-menu-empty">{accounts.error}</p>}

            {/*
              What the rows above do, for the two modes that still say anything.

              ## The switching one used to have a paragraph, and now has none

              It said the tab and the folder survive, that the agent stops and
              starts again, that it could happen now or at his next message, and
              that whether the conversation came depended on whether the two
              accounts shared a history. It was accurate, it was pinned by a
              test, and he read it out loud and asked for it to go:

                > *"here you have a very long description… Remove this full
                > shit. I don't want any kind of long descriptions anywhere."*

              The last clause had also stopped being true in the direction that
              mattered. `adoptSharedHistory` puts both accounts on one
              conversation history before the sheet is drawn, so the
              conversation comes with him — a paragraph hedging about it was
              describing a problem he no longer has, which is the worst kind of
              statement to leave on a screen. What the two buttons on the sheet
              do is written on the buttons.

              ## What is left

              `blocked` is not a description. It is a refusal with the fix in
              it, over rows that cannot be picked, and a menu that refuses
              silently is the shape of bug this chip has already been reported
              for once. The default line names what a press opens, in four
              words, because that is the one thing the rows themselves do not
              say — these open a *new* session rather than moving this one.
            */}
            {/*
              The switching case says nothing at all now, and that is the point.

                > *"Every single time you bring some card, you put something
                > new… I said to you, don't put any single statement in
                > anywhere… We want simplicity. Let the smart people use it."*

              What stood here was a paragraph explaining that a switch keeps the
              tab and the folder, that it can happen now or at his next message,
              and that whether the conversation comes depends on the two
              accounts. Every one of those is either visible in the menu itself
              — the two buttons are on the next screen, with their own labels —
              or no longer true: both accounts are put on one conversation
              history before the sheet is drawn, so the conversation comes.

              What survives is the one line that is not an explanation. `blocked`
              is a refusal with the fix in it, and a refusal with nothing to do
              about it is how a menu that cannot be used reads as one that is
              broken.
            */}
            {/* `Opens a new session here.` was the other half of this line and
                it is gone: a menu of accounts under a heading that says
                Account, whose rows start a session, does not need a sentence
                saying that rows start a session. What survives is the refusal,
                which is not a description — it is the one state where the rows
                do nothing, with the fix in it. */}
            {!switching && blocked && (
              <p className="account-menu-foot">
                Change the default coding tool in Settings to start a session under one of these.
              </p>
            )}

            {/*
              One door, not a third one.

                > *"And why do we have see sign in here separately, add account
                > here separately?"*

              This item read **Add or sign in to an account…** — both of the two
              words he was complaining about, in one label — and it opened
              Settings → Coding AI, which is the screen those two buttons are
              on. So the menu's answer to "I want another account" was to put
              him back in front of the pair he had just objected to.

              It is called what the act is called everywhere else now, and it
              opens the sign-in popup itself. The event is how, and it is a
              deliberate choice over threading an intent through the window: the
              settings sheet is opened by the shell, four components up, and the
              pane that owns the popup is `AccountsSection`. A prop for this
              would be a new field on two interfaces and a branch in the shell
              for one button. `AccountsSection` listens for this on `window` and
              opens the same popup its own button opens — see `ADD_ACCOUNT_EVENT`
              there — and the ordering is safe in either direction, because it
              re-checks the flag when it mounts.
            */}
            <button
              type="button"
              role="menuitem"
              className="folder-menu-item folder-menu-browse"
              onClick={() =>
                menu.choose(() => {
                  askForAddAccount()
                  onManage()
                })
              }
            >
              Add account
            </button>
          </div>,
          document.body,
        )}
    </div>
  )
}
