/**
 * What each control is allowed to offer, and how to describe what it does.
 *
 * Kept away from React because the interesting part of this feature is not the
 * menu — it is the claim each option makes about the CLI. Every option below
 * corresponds to something typed at the real `claude` binary on this machine,
 * and the `applies` field records how far the change reaches, which is the one
 * thing a user cannot find out by looking.
 */

export type ControlId = 'model' | 'effort' | 'fast' | 'permission'

/** Where a reading came from. Mirrors `ValueSource` in `src/main/agent-controls.ts`. */
export type ValueSource = 'screen' | 'transcript' | 'settings' | 'env'

export interface ControlOption {
  id: string
  label: string
  /** One line under the label. Says what it does, not that it is recommended. */
  hint?: string
}

export interface ControlReading {
  value: string | null
  label: string | null
  source: ValueSource | null
  unavailableReason?: string
}

export interface ControlsReading {
  model: ControlReading
  effort: ControlReading
  fast: ControlReading
  permission: ControlReading
  live: boolean
}

/**
 * The five permission modes, in the order shift+tab visits them.
 *
 * `dontAsk` is not here. `claude --permission-mode` accepts it, but it never
 * appeared in the cycle, so a running session cannot be moved into it — and a
 * menu entry that cannot do its job is worse than no entry.
 */
export const PERMISSION_OPTIONS: ControlOption[] = [
  { id: 'plan', label: 'Plan', hint: 'Research and propose; change nothing' },
  { id: 'manual', label: 'Manual', hint: 'Ask before every action that needs permission' },
  { id: 'acceptEdits', label: 'Accept edits', hint: 'File edits go through without asking' },
  { id: 'auto', label: 'Auto', hint: 'Claude judges each call and blocks risky ones' },
  { id: 'bypass', label: 'Bypass', hint: 'No permission checks at all' },
]

/**
 * Effort levels, quoted from the CLI's own rejection of a bad argument:
 * "Valid options are: low, medium, high, xhigh, max, ultracode, auto".
 */
export const EFFORT_OPTIONS: ControlOption[] = [
  { id: 'auto', label: 'Auto', hint: "The model's own default" },
  { id: 'low', label: 'Low', hint: 'Quick, minimal overhead' },
  { id: 'medium', label: 'Medium', hint: 'Standard implementation and testing' },
  { id: 'high', label: 'High', hint: 'Comprehensive, with testing and docs' },
  { id: 'xhigh', label: 'Extra high', hint: 'Deeper reasoning than high' },
  { id: 'max', label: 'Max', hint: 'Deepest reasoning available' },
  { id: 'ultracode', label: 'Ultracode', hint: 'Extra high plus dynamic workflows' },
]

/**
 * Model aliases, each typed at the real CLI and accepted by it.
 *
 * `Default` and `Opus` are not the same: the CLI answered "Opus 5 (1M context)"
 * for one and "Opus 5" for the other, so both are offered.
 *
 * This is the set of names the CLI parses, not a claim about entitlement. A
 * model this account cannot use answers `Model 'x' not found`, and that reply
 * is shown as-is rather than being hidden behind a disabled menu row we would
 * have had to guess at.
 */
export const MODEL_OPTIONS: ControlOption[] = [
  { id: 'default', label: 'Default', hint: 'Whatever the account default resolves to' },
  { id: 'opus', label: 'Opus' },
  { id: 'fable', label: 'Fable' },
  { id: 'sonnet', label: 'Sonnet' },
  { id: 'haiku', label: 'Haiku' },
]

export const FAST_OPTIONS: ControlOption[] = [
  { id: 'off', label: 'Off' },
  { id: 'on', label: 'On', hint: 'Draws from usage credits at a higher rate' },
]

export function optionsFor(control: ControlId): ControlOption[] {
  if (control === 'model') return MODEL_OPTIONS
  if (control === 'effort') return EFFORT_OPTIONS
  if (control === 'fast') return FAST_OPTIONS
  return PERMISSION_OPTIONS
}

/**
 * How far a change reaches. Shown on the menu because it is invisible otherwise
 * and it is the thing most likely to surprise someone.
 *
 * Verified from the CLI's own confirmations: `/effort xhigh` answered "saved as
 * your default for new sessions" and `/model sonnet` answered "and saved as
 * your default for new sessions", while the permission cycle is session-only —
 * the CLI logs "setMode is session-scoped; not persisting as defaultMode".
 */
export function reachOf(control: ControlId): string {
  if (control === 'permission') return 'This session only'
  if (control === 'fast') return 'This session, and saved as the default'
  return 'This session, and saved as the default for new sessions'
}

/** The short caption under a control's value, naming where the value came from. */
export function sourceNote(source: ValueSource | null): string {
  if (source === 'screen') return 'read from this session'
  if (source === 'transcript') return 'from the last reply'
  if (source === 'settings') return 'from Claude settings'
  if (source === 'env') return 'set by CLAUDE_CODE_EFFORT_LEVEL'
  return 'not known'
}

/**
 * The label to print for a reading.
 *
 * There is no fallback to a plausible default here on purpose. When nothing
 * real was read the answer is the word "Unknown", because a control showing a
 * confident value it never read is the failure mode this feature exists to
 * avoid.
 */
export function displayValue(reading: ControlReading | undefined): string {
  if (!reading || reading.label === null) return 'Unknown'
  return reading.label
}

/**
 * True when the menu should mark this option as the one currently in force.
 *
 * Effort, fast mode and permission read back as the exact id that was sent, so
 * those are a straight comparison. The model does not: it comes back as a
 * display name — "Sonnet 5", "Opus 5 (1M context) (default)" — or, from the
 * transcript, as a raw id relabelled to "Opus 5 · 1M". So the model is matched
 * on the family word at the front of the label, and the CLI's own "(default)"
 * marker is what distinguishes Default from Opus, since both are Opus 5.
 *
 * A tick is a claim, so an unreadable value ticks nothing.
 */
export function isCurrent(reading: ControlReading | undefined, option: ControlOption): boolean {
  if (!reading || reading.value === null) return false
  if (reading.value === option.id) return true
  const shown = (reading.label ?? '').toLowerCase()
  if (shown === '') return false
  if (shown.includes('(default)')) return option.id === 'default'
  return shown.startsWith(`${option.label.toLowerCase()} `)
}
