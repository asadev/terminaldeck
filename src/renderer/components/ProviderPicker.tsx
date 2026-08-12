import { useCallback, useEffect, useId, useMemo, useState, type FormEvent } from 'react'
import type { ProviderId } from '@shared/types'
import { folderName } from '../session-title'
import { Modal } from './Modal'
import { installedProviders } from './PreferencesModal'
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
 * `codex resume --last` exist, the Gemini CLI has no equivalent flag, and a
 * shell has no session to resume.
 */
export interface ProviderOption {
  id: ProviderId
  label: string
  /** One line under the label: what this agent is. */
  description: string
  /** What the user would run to get it, shown only when it is missing. */
  install: string | null
  canResume: boolean
}

export const PROVIDER_OPTIONS: readonly ProviderOption[] = [
  {
    id: 'claude',
    label: 'Claude Code',
    description: "Anthropic's agentic CLI. Writes transcripts, so cost and context tracking work.",
    install: 'npm install -g @anthropic-ai/claude-code',
    canResume: true,
  },
  {
    id: 'codex',
    label: 'Codex CLI',
    description: "OpenAI's coding agent.",
    install: 'npm install -g @openai/codex',
    canResume: true,
  },
  {
    id: 'gemini',
    label: 'Gemini CLI',
    description: "Google's coding agent.",
    install: 'npm install -g @google/gemini-cli',
    canResume: false,
  },
  {
    id: 'shell',
    label: 'Shell',
    description: 'A plain login shell. No agent, no telemetry — just a terminal.',
    install: null,
    canResume: false,
  },
]

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

    void window.pawl.detectProviders().then(
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
            <label
              key={row.id}
              className="picker-option"
              data-selected={row.id === selected}
              data-available={row.available}
            >
              <input
                type="radio"
                name={`${formId}-provider`}
                value={row.id}
                checked={row.id === selected}
                disabled={!row.available}
                onChange={() => setSelected(row.id)}
              />
              <span className="picker-mark" aria-hidden="true" />
              <span className="picker-text">
                <span className="picker-label">
                  {row.label}
                  {!row.available && <span className="picker-tag">Not installed</span>}
                </span>
                <span className="picker-hint">{row.reason ?? row.description}</span>
                {!row.available && row.install && <code className="picker-install">{row.install}</code>}
              </span>
            </label>
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
