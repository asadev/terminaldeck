import { useCallback, useEffect, useId, useMemo, useState, type FormEvent } from 'react'
import type { ProviderId } from '@shared/types'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a
// test. `McpServers.tsx` and `PowerSection.tsx` carry the same note for the
// same reason; a type-only import is fine either way because it is erased.
import { AGENT_ENTRIES, AGENT_CATALOG, hasAnyLogin, type AgentEntry } from '../../shared/agent-catalog'
import { allAgentEntries, type CustomAgent } from '../../shared/custom-agents'
import { BRAND } from '../../shared/brand'
import { folderName } from '../session-title'
import { Modal } from './Modal'
import { ProviderBadge } from './ProviderBadge'
import { installedProviders } from '../preferences'
import './ProviderPicker.css'

/**
 * Choosing the agent a new session runs, and whether it starts fresh or picks
 * up where the folder left off.
 *
 * Picking an agent that is not installed is the failure this dialog exists to
 * prevent: the spawn silently falls back to a plain shell, and the user is
 * left staring at a prompt wondering why Claude never started. So every
 * provider is listed — a missing one is information, not something to hide —
 * but an uninstalled one cannot be selected, and says why and how to fix it.
 */

/**
 * The provider catalogue, as the renderer needs it.
 *
 * Deliberately not imported from `src/main/providers.ts`: that module runs
 * `execFile` at import time-adjacent scope and is Node-only, so pulling it
 * across the bridge would drag the child-process API into the browser bundle.
 * The overlap is four labels and two booleans; the IPC boundary already
 * carries the part that matters, which is what is actually on PATH.
 *
 * `canResume` mirrors `resumeArgs` in that module — `claude --continue` and
 * `codex resume --last` exist, a shell has no session to resume, and Gemini's
 * `--resume latest` is documented in its own `--help` but deliberately unused:
 * the case that decides whether it is safe (a folder with no previous session)
 * could not be exercised on the machine this was written on. `providers.ts`
 * carries the full note; `false` here is what keeps the dialog from offering
 * something the spawn will not do.
 */
export interface ProviderOption {
  id: ProviderId
  label: string
  /** One line under the label: what this agent is. */
  description: string
  /** What the user would run to get it, shown only when it is missing. */
  install: string | null
  /**
   * The program this agent runs, or null for the shell.
   *
   * Carried because it is what the "could not start" sentence has to name, and
   * for an agent somebody added it is not the id: the id is `custom:grok` and
   * the thing they typed — the thing they can go and check — is `grok`. Printing
   * the id there told a person their machine could not start something they had
   * never heard of. Null only for the shell, which is `$SHELL` or `%COMSPEC%`
   * and is never reported missing.
   */
  command: string | null
  canResume: boolean
  /**
   * Whether this app can keep two logins of this agent apart.
   *
   * Mirrors `supportsAccounts` in `src/main/provider-accounts.ts`, which is
   * where the evidence for each answer is written down and where the decision
   * is made. The copy exists because a dialog has to draw its list before any
   * IPC has answered, and a picker whose rows change from selectable to
   * disabled a beat after it opens is a picker somebody clicks the wrong row
   * in. `ProviderPicker.test.ts` imports the main-process table and fails if
   * the two disagree — a comment asking two files to stay in step is the thing
   * this codebase keeps discovering was not enough.
   */
  canHaveAccounts: boolean
  /**
   * The one-line version of *why not*, for the Add-account list.
   *
   * A summary, not a second copy of the main process's paragraph: the full
   * measured reason comes over `profiles:account-providers` and replaces this
   * as soon as it lands. Written to be true on its own, because on a window
   * whose bridge is missing this is the only sentence there will ever be.
   */
  accountsNote: string | null
}

/**
 * Built from `shared/agent-catalog.ts`, not written out here.
 *
 * The list this replaced was four object literals holding the same labels,
 * descriptions, install commands and booleans that the main process kept in two
 * other files — and the comment above already had to explain how the copies were
 * meant to stay in step. They are now one declaration read from both sides, so
 * the answer to *"there should be a plus button to add with the big list of type
 * of AI agents to connect"* is an entry in that table rather than an edit here.
 *
 * `canHaveAccounts` is `logins === 'multiple'` and nothing else: an agent that
 * keeps one login per machine is still an agent you sign into, and conflating
 * the two is what left Gemini with no row on the Accounts screen.
 */
const toOption = (entry: AgentEntry): ProviderOption => ({
  id: entry.id,
  label: entry.label,
  description: entry.description,
  install: entry.install,
  command: entry.bin,
  canResume: entry.resumeArgs.length > 0,
  canHaveAccounts: entry.logins === 'multiple',
  accountsNote: entry.logins === 'multiple' ? null : entry.loginsNote,
})

export const PROVIDER_OPTIONS: readonly ProviderOption[] = AGENT_ENTRIES.map(toOption)

/**
 * The shipped agents, then the ones this machine added.
 *
 * `allAgentEntries` decides the order and says why it is not alphabetical: the
 * builtins first because they are the ones with resume, accounts and the rest,
 * a person's own additions under them the way "Your agents" sits under a gallery
 * in every editor that does this.
 *
 * A function of the added list rather than a module constant, because the added
 * list is per machine and arrives over the bridge. `PROVIDER_OPTIONS` stays a
 * constant and stays the first paint: a dialog that drew nothing until an IPC
 * answered would flash empty every time it opened.
 */
export function providerOptionsWith(added: readonly CustomAgent[]): readonly ProviderOption[] {
  return allAgentEntries(AGENT_ENTRIES, added).map(toOption)
}

/** The catalogue entry for an id, or undefined for one this build does not know. */
export function providerOption(id: ProviderId): ProviderOption | undefined {
  return PROVIDER_OPTIONS.find((option) => option.id === id)
}

/**
 * The agents that can hold an account, in catalogue order.
 *
 * The Add-account dialog lists *every* agent and disables the rest, so this is
 * not what it renders from — it is for callers that need the answer rather than
 * the list, and for the test that checks it against the main process.
 */
export function accountProviderIds(): ProviderId[] {
  return PROVIDER_OPTIONS.filter((option) => option.canHaveAccounts).map((option) => option.id)
}

/** A provider plus everything this dialog knows about whether it can be used. */
export interface ProviderRow extends ProviderOption {
  available: boolean
  /** Why it cannot be picked, or null when it can. */
  reason: string | null
}

/**
 * Decorate the catalogue with detection results.
 *
 * Fails open, exactly as the preferences form does: an unreadable or empty
 * detection result means "unknown", and locking every agent out on the
 * strength of a failed `which` would make the app useless for the case it is
 * least able to diagnose. `installedProviders` already encodes that
 * distinction — null for unknown, `[]` for a real all-missing answer — so it
 * is reused here rather than reimplemented and left to drift.
 */
export function buildProviderRows(
  detected: unknown,
  added: readonly CustomAgent[] = [],
): ProviderRow[] {
  const installed = installedProviders(detected)
  return providerOptionsWith(added).map((option) => {
    // A shell always exists — it is how the app spawns everything else.
    const available = option.id === 'shell' || installed === null || installed.includes(option.id)
    return {
      ...option,
      available,
      /*
       * "Could not start", not "was not found on your PATH".
       *
       * `detectProviders` no longer answers a lookup — it runs each agent once
       * to prove it starts, because a `codex` that resolves on PATH and then
       * dies with a spawn error is the exact case that put a Node stack trace in
       * front of the user. So an unavailable row here covers two situations, and
       * the old sentence was flatly wrong about the second one: the binary *was*
       * on his PATH. This sentence is true of both, and the install line
       * underneath is the fix for both — installing it, or replacing a copy that
       * does not work.
       *
       * The *command*, not the id, and `BRAND.name`, not the words. Both were
       * wrong in one line: an agent somebody added has the id `custom:grok`, so
       * the sentence read "could not start `custom:grok`", naming a string the
       * person has never seen instead of the `grok` they typed into the form;
       * and the product's name was spelled here rather than read from the one
       * place that holds it.
       */
      reason: available
        ? null
        : `${BRAND.name} could not start \`${option.command ?? option.id}\` on this machine.`,
    }
  })
}

/** Whether "continue the last session" applies, and why not when it does not. */
export function resumeAvailability(row: ProviderRow | undefined): {
  enabled: boolean
  reason: string | null
} {
  if (!row) return { enabled: false, reason: null }
  if (!row.available) return { enabled: false, reason: null }
  if (!row.canResume) return { enabled: false, reason: `${row.label} has no resume command.` }
  return { enabled: true, reason: null }
}

/** First selectable row, used when the caller's default is not installed. */
export function firstAvailable(rows: readonly ProviderRow[]): ProviderId | null {
  return rows.find((row) => row.available)?.id ?? null
}

export interface ProviderChoice {
  provider: ProviderId
  /** Continue the most recent session in this folder instead of starting fresh. */
  resume: boolean
}

/* ------------------------------------------------------------------- row -- */

interface RowProps {
  row: ProviderRow
  /** Radio group name. Two pickers can be mounted at once; their rows must not join. */
  group: string
  selected: boolean
  onSelect(id: ProviderId): void
  /**
   * Replaces the row's usual hint.
   *
   * The Add-account list answers a different question from the New-session
   * list — "can this agent hold a second login" rather than "is this agent
   * installed" — and a row that answered the wrong one would be a row that
   * looks like it is explaining itself while explaining something else.
   */
  hint?: string | null
  /** Extra reason this row cannot be picked, on top of not being installed. */
  disabledReason?: string | null
  /** The word in the pill on the right. Absent draws no pill. */
  tag?: string | null
  /**
   * Draw the name and the pill, and no line of explanation under either.
   *
   * The Add-account popup sets it. That list carried a sentence per row —
   * *"Anthropic's agentic CLI. Writes transcripts, so token and context
   * tracking work."*, *"OpenAI's coding agent…"*, and for Gemini a six-line
   * paragraph about keychain entries being shared across configuration
   * directories — under a heading asking which agent a login is for. His words,
   * of this exact popup:
   *
   *   > *"If we want to add account, this big description again here also, big
   *   > description. They are not stupid to give this much."*
   *
   * The pill keeps the only part that is a fact rather than a description —
   * `Not installed`, `One login only` — and the install command stays, because
   * a command is a thing to do. The New-session picker does **not** set this:
   * there the description is what somebody is choosing *between*, and it is the
   * one list in the app where the agents are the subject rather than the
   * account is.
   */
  quiet?: boolean
}

/**
 * One selectable agent.
 *
 * Extracted so the New-session picker and the Add-account picker are literally
 * the same row rather than two lists that look alike today. They already
 * diverged once: the account concept was Claude-only and the only place that
 * said so was a paragraph in the Accounts screen, which is exactly the sort of
 * fact that is true in one list and forgotten in the next.
 */
function AgentRow({ row, group, selected, onSelect, hint, disabledReason, tag, quiet }: RowProps) {
  const blocked = disabledReason ?? null
  const available = row.available && blocked === null

  return (
    <label className="picker-option" data-selected={selected} data-available={available}>
      <input
        type="radio"
        name={group}
        value={row.id}
        checked={selected}
        disabled={!available}
        onChange={() => onSelect(row.id)}
      />
      <span className="picker-mark" aria-hidden="true" />
      <span className="picker-text">
        <span className="picker-label">
          {/* The mark, beside the name, in the one dialog whose whole subject is
              which agent this is. It is `aria-hidden` because the name is right
              there — see `ProviderBadge`. */}
          <ProviderBadge provider={row.id} />
          {row.label}
          {tag !== undefined && tag !== null && <span className="picker-tag">{tag}</span>}
          {tag === undefined && !row.available && <span className="picker-tag">Not installed</span>}
        </span>
        {!quiet && <span className="picker-hint">{hint ?? row.reason ?? row.description}</span>}
        {!row.available && row.install && <code className="picker-install">{row.install}</code>}
      </span>
    </label>
  )
}

interface Props {
  open: boolean
  /** Folder the session will run in. Shown so the target is never a guess. */
  projectPath: string | null
  /** Preselected on open — the project's default, or the global one. */
  defaultProvider?: ProviderId
  onClose(): void
  onPick(choice: ProviderChoice): void
}

export function ProviderPicker({ open, projectPath, defaultProvider, onClose, onPick }: Props) {
  const [detected, setDetected] = useState<unknown>(null)
  const [selected, setSelected] = useState<ProviderId>(defaultProvider ?? 'claude')
  const [resume, setResume] = useState(false)
  const formId = useId()

  const rows = useMemo(() => buildProviderRows(detected), [detected])
  const current = rows.find((row) => row.id === selected)
  const resumeState = resumeAvailability(current)

  useEffect(() => {
    if (!open) return
    let cancelled = false

    // Reset on every open rather than on close: leaving the previous visit's
    // answers on screen while a fresh detection is in flight lets the user
    // start a session against a provider that has since been uninstalled.
    setDetected(null)
    setResume(false)
    setSelected(defaultProvider ?? 'claude')

    void window.deck.detectProviders().then(
      (found) => {
        if (!cancelled) setDetected(found)
      },
      () => {
        // Detection failing leaves everything selectable — see buildProviderRows.
        if (!cancelled) setDetected(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open, defaultProvider])

  // Move off a provider that detection has just revealed to be missing. Doing
  // this here rather than in the fetch handler keeps it true no matter how the
  // selection got into that state.
  useEffect(() => {
    if (!open || current?.available !== false) return
    const fallback = firstAvailable(rows)
    if (fallback) setSelected(fallback)
  }, [open, current, rows])

  const submit = useCallback(
    (event: FormEvent) => {
      event.preventDefault()
      if (!current?.available) return
      onPick({ provider: current.id, resume: resume && resumeState.enabled })
    },
    [current, onPick, resume, resumeState.enabled],
  )

  const where = projectPath ? folderName(projectPath) : null

  return (
    <Modal
      open={open}
      title="New session"
      description={where ? `Runs in ${where}.` : 'Choose the agent for this session.'}
      onClose={onClose}
      size="lg"
      footer={
        <>
          <button type="button" className="modal-btn" onClick={onClose}>
            Cancel
          </button>
          {/* Associated by `form` rather than nested, because the footer is a
              sibling of the modal body, not a descendant of it. */}
          <button
            type="submit"
            form={formId}
            className="modal-btn primary"
            disabled={!current?.available}
          >
            Start session
          </button>
        </>
      }
    >
      <form id={formId} className="picker" onSubmit={submit}>
        {projectPath && (
          <p className="picker-path" title={projectPath}>
            {projectPath}
          </p>
        )}

        <div className="picker-list" role="radiogroup" aria-label="Agent">
          {rows.map((row) => (
            <AgentRow
              key={row.id}
              row={row}
              group={`${formId}-provider`}
              selected={row.id === selected}
              onSelect={setSelected}
            />
          ))}
        </div>

        <label className="picker-resume" data-enabled={resumeState.enabled}>
          <input
            type="checkbox"
            checked={resume && resumeState.enabled}
            disabled={!resumeState.enabled}
            onChange={(event) => setResume(event.target.checked)}
          />
          <span className="picker-text">
            <span className="picker-label">Continue the last session in this folder</span>
            <span className="picker-hint">
              {resumeState.reason ?? 'Picks up the most recent conversation instead of starting fresh.'}
            </span>
          </span>
        </label>
      </form>
    </Modal>
  )
}

/* -------------------------------------------------- adding an account -- */

/**
 * Which agent's account is being added — the question the app never asked.
 *
 * > *"If I add any new account it just redirects me to claude only, not to the
 * > other ones I want to connect. So there should be a way — I should be able to
 * > choose which LLM I want to connect."*
 *
 * The engine was never Claude-only; the *concept* was. An account is a config
 * directory handed to an agent CLI, and until this list existed there was
 * nowhere to say which CLI. So this is the missing first step, and the Accounts
 * pane draws it above the name field: pick the agent, then name the account,
 * then sign in *inside a session on that agent*, which is how a fresh Claude
 * account has always been signed in here and works unchanged for Codex.
 *
 * ## Why the refused agents are still listed
 *
 * Because a missing row is indistinguishable from a bug, and because Gemini is
 * the row this list most needs to explain. Gemini has a config-directory
 * variable and it does not move the login — two Gemini accounts would address
 * one keychain entry, and signing into the second would overwrite the first.
 * `provider-accounts.ts` holds that measurement and the sentence; this shows it
 * on the row rather than leaving somebody to conclude the app forgot Gemini.
 */
export interface AccountProviderView {
  id: string
  label: string
  /** Whether a *second* account of this agent can be added. */
  supported: boolean
  /** Whether this agent has a login at all — one or many. */
  canSignIn: boolean
  configEnv: string | null
  reason: string | null
}

/**
 * Narrow the `profiles:account-providers` answer.
 *
 * Returns an empty list for anything unrecognised, and the list then draws from
 * its own catalogue — which has the same booleans and shorter sentences. A
 * screen that refused to draw because an IPC answered oddly would be worse than
 * one that draws with less to say.
 */
export function parseAccountProviders(value: unknown): AccountProviderView[] {
  const raw = typeof value === 'object' && value !== null ? (value as { providers?: unknown }) : null
  if (!Array.isArray(raw?.providers)) return []

  const views: AccountProviderView[] = []
  for (const entry of raw.providers) {
    if (typeof entry !== 'object' || entry === null) continue
    const row = entry as Record<string, unknown>
    if (typeof row.id !== 'string' || row.id === '') continue
    views.push({
      id: row.id,
      label: typeof row.label === 'string' && row.label !== '' ? row.label : row.id,
      // Only an explicit `true` is support. An answer this build cannot read
      // must not turn into an offer to isolate a login it cannot isolate.
      supported: row.supported === true,
      // Defaults to `supported` for an older main process that does not send
      // this field: an agent that can hold two logins can certainly hold one, so
      // the fallback is never an over-claim.
      canSignIn: row.canSignIn === true || row.supported === true,
      configEnv: typeof row.configEnv === 'string' ? row.configEnv : null,
      reason: typeof row.reason === 'string' && row.reason !== '' ? row.reason : null,
    })
  }
  return views
}

/** A row of the Add-account list: the catalogue, plus whatever IPC said. */
export interface AccountProviderRow extends ProviderRow {
  /** Selectable in the Add form: runnable, and able to hold a *second* login. */
  canAdd: boolean
  /**
   * Has a login of its own that the Accounts screen should show a row for.
   *
   * True for Gemini, which `canAdd` is false for. Keeping them apart is the
   * whole Gemini fix: one predicate answered both questions, the answer was no,
   * and the agent vanished from the screen instead of appearing once.
   */
  canSignIn: boolean
  /** Why there is no second one. Null when there can be. */
  note: string | null
}

/**
 * Fold the main process's answer into the catalogue.
 *
 * The catalogue decides *shape* — which agents exist, in what order, and
 * whether each is installed — and the main process decides *truth* about
 * accounts, because that is where the mechanism lives and where it was
 * measured. When the two disagree the main process wins, and when it has not
 * answered yet the catalogue's own booleans are used, which is why they are
 * pinned against each other by a test.
 */
export function buildAccountProviderRows(
  detected: unknown,
  fromMain: readonly AccountProviderView[] = [],
): AccountProviderRow[] {
  return buildProviderRows(detected)
    // A shell is not an account holder and never will be, and unlike Gemini
    // there is nothing to explain — listing it would put a row in the dialog
    // whose only content is "this is not an agent".
    .filter((row) => row.id !== 'shell')
    .map((row) => {
      const option = providerOption(row.id)
      const said = fromMain.find((entry) => entry.id === row.id)
      const supported = said?.supported ?? option?.canHaveAccounts ?? false
      const note = supported ? null : (said?.reason ?? option?.accountsNote ?? null)
      const catalogEntry = AGENT_CATALOG[row.id]
      return {
        ...row,
        canAdd: supported && row.available,
        /*
         * The catalogue answers this until the main process does, and `??`
         * cannot be chained through `supported` to get there: `supported` is a
         * boolean, so `false ?? x` is `false`, and Gemini — the one agent whose
         * two answers differ — came back unsignable on every paint before the
         * IPC landed.
         *
         * `hasAnyLogin` rather than `logins !== 'none'`, which is the same
         * answer for every agent in the shipped table and a different one for an
         * agent somebody added: that reads `unmeasured`, and `!== 'none'` would
         * turn *nobody has looked* into a sign-in offer for a CLI this build has
         * never watched store a credential.
         */
        canSignIn: said?.canSignIn ?? (catalogEntry ? hasAnyLogin(catalogEntry.id) : supported),
        note,
      }
    })
}

/** First agent that can actually take a new account. */
export function firstAccountProvider(rows: readonly AccountProviderRow[]): ProviderId | null {
  return rows.find((row) => row.canAdd)?.id ?? null
}

/**
 * The Add-account list, ready to draw.
 *
 * Both the two questions behind it are asked here — what is on PATH, and which
 * agents this build will isolate — because they arrive separately and neither
 * of them is allowed to hold the list back. The catalogue's own booleans are
 * what the first paint uses, so the rows are correct before either answers and
 * do not change from selectable to disabled under a pointer already moving.
 *
 * @param active false parks it: nothing is fetched and the last answers are
 *   dropped. A dialog passes `open` so that reopening it re-detects rather than
 *   offering an agent that was uninstalled in between; a settings pane that is
 *   only mounted while it is on screen passes `true`.
 */
export function useAccountProviderRows(active: boolean): AccountProviderRow[] {
  const [detected, setDetected] = useState<unknown>(null)
  const [fromMain, setFromMain] = useState<readonly AccountProviderView[]>([])

  useEffect(() => {
    if (!active) return
    let cancelled = false

    // Reset on open, not on close: leaving the previous visit's answers up
    // while a fresh detection is in flight is how somebody adds an account for
    // an agent that has since been uninstalled.
    setDetected(null)
    setFromMain([])

    const bridge = (globalThis as { deck?: Record<string, unknown> }).deck
    const detect = bridge?.detectProviders
    if (typeof detect === 'function') {
      void (detect as () => Promise<unknown>)().then(
        (found) => {
          if (!cancelled) setDetected(found)
        },
        () => {
          if (!cancelled) setDetected(null)
        },
      )
    }

    const ask = bridge?.accountProviders
    if (typeof ask === 'function') {
      void (ask as () => Promise<unknown>)().then(
        (answer) => {
          if (!cancelled) setFromMain(parseAccountProviders(answer))
        },
        () => {
          // The catalogue's own booleans stand. They are the same booleans;
          // only the sentences are shorter.
          if (!cancelled) setFromMain([])
        },
      )
    }

    return () => {
      cancelled = true
    }
  }, [active])

  return useMemo(() => buildAccountProviderRows(detected, fromMain), [detected, fromMain])
}

interface AccountListProps {
  /** Radio group name. Two of these can be mounted at once; their rows must not join. */
  group: string
  rows: readonly AccountProviderRow[]
  selected: ProviderId | null
  onSelect(id: ProviderId): void
}

/**
 * "Which agent is this a login for?", as a list of rows.
 *
 * A component rather than a loop written twice, because the two places that ask
 * it — the Accounts pane's Add form and the dialog below — must give the same
 * answer, and the row that matters most is the one nobody clicks. Gemini is
 * *listed*, disabled: a missing row is indistinguishable from an oversight, and
 * Gemini is the agent somebody will most reasonably assume was forgotten,
 * because it does have a config-directory variable. What it does not have is a
 * way to keep two logins apart — `provider-accounts.ts` holds the measurement —
 * so signing into a second Gemini account would overwrite the first rather than
 * sit beside it.
 *
 * The measured reason used to be *beside* the row, and on Gemini that is six
 * lines about a keychain entry shared across configuration directories — the
 * longest single block of prose on any account surface, spent explaining why an
 * option nobody can pick is grey. `quiet` is what takes it off: the pill says
 * **One login only**, which is the fact, and the paragraph is not replaced by a
 * shorter paragraph.
 */
export function AccountProviderList({ group, rows, selected, onSelect }: AccountListProps) {
  return (
    <div className="picker-list" role="radiogroup" aria-label="Agent">
      {rows.map((row) => (
        <AgentRow
          key={row.id}
          row={row}
          group={group}
          selected={row.id === selected}
          onSelect={onSelect}
          // An agent that is not installed keeps its own "not installed"
          // reason and install line; one that is installed but cannot hold
          // a second login gets the sentence explaining that instead.
          quiet
          disabledReason={row.canAdd ? null : (row.note ?? 'Not available.')}
          tag={row.available && !row.canAdd ? 'One login only' : undefined}
        />
      ))}
    </div>
  )
}

/**
 * Which agent a new account will actually belong to, given what was clicked.
 *
 * Derived, never stored, and that is the whole point of it being a function.
 * The rows change under the selection twice — once when `detectProviders`
 * answers and once when the main process does — so a selection kept in state
 * has to be corrected by an effect, and an effect does not run on the first
 * paint. That is the paint where nobody has clicked anything yet and the form
 * must still show which agent Add would use. Computing it instead means the
 * answer is right immediately and stays right when a row stops being addable,
 * with no render in between where Add is lit over a row that refuses.
 *
 * Null only when no agent on this machine can take an account at all.
 */
export function chosenAccountProvider(
  rows: readonly AccountProviderRow[],
  selected: ProviderId | null,
): AccountProviderRow | null {
  return (
    rows.find((row) => row.id === selected && row.canAdd) ?? rows.find((row) => row.canAdd) ?? null
  )
}

/*
 * The Add-account dialog is not here, and the reason it is not a `Modal` is
 * worth keeping.
 *
 * One was written as a `Modal` the Accounts pane would open, and it could not
 * ship: `Modal` binds Escape to `window`, the Settings sheet is itself a
 * `Modal`, and listeners on one target fire in the order they were added — so
 * Escape inside a dialog opened from Settings closes Settings *and* the dialog,
 * throwing away the pane the user was working in. For a while the pane drew
 * these three pieces inline instead.
 *
 * The review of 2026-08-17 asked for the popup by name — *"'Add' and 'Sign in'
 * should be one thing, called Add account. It must open a small popup with only
 * the sign-in steps"* — so it exists again, as
 * `settings/sections/AddAccountDialog.tsx`, and it is not a `Modal`. It catches
 * Escape on `document` in the **capture** phase, which runs before the event
 * reaches any window-level bubble listener, exactly as `ShortcutsPopover` in
 * the same window already does. One Escape closes the popup; a second closes
 * Settings.
 */
