import { useCallback, useEffect, useId, useMemo, useState, type FormEvent } from 'react'
import type { ProviderId } from '@shared/types'
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

export const PROVIDER_OPTIONS: readonly ProviderOption[] = [
  {
    id: 'claude',
    label: 'Claude Code',
    description: "Anthropic's agentic CLI. Writes transcripts, so cost and context tracking work.",
    install: 'npm install -g @anthropic-ai/claude-code',
    canResume: true,
    canHaveAccounts: true,
    accountsNote: null,
  },
  {
    id: 'codex',
    label: 'Codex CLI',
    description: "OpenAI's coding agent. Sign in with a ChatGPT account.",
    install: 'npm install -g @openai/codex',
    canResume: true,
    canHaveAccounts: true,
    accountsNote: null,
  },
  {
    id: 'gemini',
    label: 'Gemini CLI',
    description: "Google's coding agent.",
    install: 'npm install -g @google/gemini-cli',
    canResume: false,
    canHaveAccounts: false,
    accountsNote:
      'Gemini stores one login per machine, in a place a second account cannot be pointed at. Gemini sessions use the Google account you are already signed into.',
  },
  {
    id: 'shell',
    label: 'Shell',
    description: 'A plain login shell. No agent, no telemetry — just a terminal.',
    install: null,
    canResume: false,
    canHaveAccounts: false,
    accountsNote: 'A shell has no login to sign in to.',
  },
]

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
export function buildProviderRows(detected: unknown): ProviderRow[] {
  const installed = installedProviders(detected)
  return PROVIDER_OPTIONS.map((option) => {
    // A shell always exists — it is how the app spawns everything else.
    const available = option.id === 'shell' || installed === null || installed.includes(option.id)
    return {
      ...option,
      available,
      reason: available ? null : `\`${option.id}\` was not found on your PATH.`,
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
function ProviderRow({ row, group, selected, onSelect, hint, disabledReason, tag }: RowProps) {
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
        <span className="picker-hint">{hint ?? row.reason ?? row.description}</span>
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
            <ProviderRow
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
 * directory handed to an agent CLI, and until this dialog existed there was
 * nowhere to say which CLI. So this is the missing first step: pick the agent,
 * then name the account, then sign in *inside a session on that agent*, which is
 * how a fresh Claude account has always been signed in here and works unchanged
 * for Codex.
 *
 * ## Why the refused agents are still listed
 *
 * Because a missing row is indistinguishable from a bug, and because Gemini is
 * the row this dialog most needs to explain. Gemini has a config-directory
 * variable and it does not move the login — two Gemini accounts would address
 * one keychain entry, and signing into the second would overwrite the first.
 * `provider-accounts.ts` holds that measurement and the sentence; this shows it
 * on the row rather than leaving somebody to conclude the app forgot Gemini.
 */
export interface AccountProviderView {
  id: string
  label: string
  supported: boolean
  configEnv: string | null
  reason: string | null
}

/**
 * Narrow the `profiles:account-providers` answer.
 *
 * Returns an empty list for anything unrecognised, and the dialog then draws
 * from its own catalogue — which has the same booleans and shorter sentences.
 * A dialog that refused to open because an IPC answered oddly would be worse
 * than one that opens with less to say.
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
      configEnv: typeof row.configEnv === 'string' ? row.configEnv : null,
      reason: typeof row.reason === 'string' && row.reason !== '' ? row.reason : null,
    })
  }
  return views
}

/** A row of the Add-account list: the catalogue, plus whatever IPC said. */
export interface AccountProviderRow extends ProviderRow {
  /** Selectable: installed, and able to hold an account of its own. */
  canAdd: boolean
  /** Why not. Null when it can. */
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
      return {
        ...row,
        canAdd: supported && row.available,
        note,
      }
    })
}

/** First agent that can actually take a new account. */
export function firstAccountProvider(rows: readonly AccountProviderRow[]): ProviderId | null {
  return rows.find((row) => row.canAdd)?.id ?? null
}

interface AccountPickerProps {
  open: boolean
  onClose(): void
  /** Runs with the chosen agent. The caller names the account and signs it in. */
  onPick(provider: ProviderId): void
}

export function AccountProviderPicker({ open, onClose, onPick }: AccountPickerProps) {
  const [detected, setDetected] = useState<unknown>(null)
  const [fromMain, setFromMain] = useState<readonly AccountProviderView[]>([])
  const [selected, setSelected] = useState<ProviderId | null>(null)
  const formId = useId()

  const rows = useMemo(() => buildAccountProviderRows(detected, fromMain), [detected, fromMain])
  const current = rows.find((row) => row.id === selected) ?? null

  useEffect(() => {
    if (!open) return
    let cancelled = false

    // Reset on open, not on close: leaving the previous visit's answers up
    // while a fresh detection is in flight is how somebody adds an account for
    // an agent that has since been uninstalled.
    setDetected(null)
    setFromMain([])
    setSelected(null)

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
  }, [open])

  // Preselect the first agent that can take an account, and move off one that
  // an arriving answer has just ruled out. Done here rather than in the fetch
  // handlers so it holds however the selection got into that state.
  useEffect(() => {
    if (!open) return
    if (current?.canAdd === true) return
    setSelected(firstAccountProvider(rows))
  }, [open, current, rows])

  const submit = useCallback(
    (event: FormEvent) => {
      event.preventDefault()
      if (!current?.canAdd) return
      onPick(current.id)
    },
    [current, onPick],
  )

  return (
    <Modal
      open={open}
      title="Add an account"
      description="Which agent is this a login for?"
      onClose={onClose}
      size="lg"
      footer={
        <>
          <button type="button" className="modal-btn" onClick={onClose}>
            Cancel
          </button>
          <button
            type="submit"
            form={formId}
            className="modal-btn primary"
            disabled={!current?.canAdd}
          >
            Continue
          </button>
        </>
      }
    >
      <form id={formId} className="picker" onSubmit={submit}>
        <div className="picker-list" role="radiogroup" aria-label="Agent">
          {rows.map((row) => (
            <ProviderRow
              key={row.id}
              row={row}
              group={`${formId}-account-provider`}
              selected={row.id === selected}
              onSelect={setSelected}
              // An agent that is not installed keeps its own "not installed"
              // reason and install line; one that is installed but cannot hold
              // a second login gets the sentence explaining that instead.
              hint={row.available ? row.note : null}
              disabledReason={row.canAdd ? null : (row.note ?? 'Not available.')}
              tag={row.available && !row.canAdd ? 'One login only' : undefined}
            />
          ))}
        </div>
      </form>
    </Modal>
  )
}
