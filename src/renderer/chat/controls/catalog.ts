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
  // "this session only" is not a guess: the CLI has no other answer for
  // ultracode — `Set effort level to ultracode (this session only): xhigh +
  // dynamic workflow orchestration` is the whole of it, with no branch.
  { id: 'ultracode', label: 'Ultracode', hint: 'Extra high plus dynamic workflows · this session only' },
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
 * What the Options panel lists: **every** control the app has.
 *
 * There used to be a second list here called `FOLDED_CONTROLS`, holding the two
 * that the panel showed and the composer's row did not, and it is worth writing
 * down why it is gone rather than quietly deleting it. Asked for "one large
 * chat box with the options folded neatly inside it", a pass over this composer
 * put model and permission on the row, effort and fast mode behind a button
 * labelled "More", and the usage readout behind it too. Read back from the
 * screen, that is not a fold — nothing on screen said the word "effort", so
 * there was no way to look for it, and the report was: "all the options you
 * have actually removed."
 *
 * So the panel is the complete inventory, and hiding is no longer something
 * this file can express.
 *
 * The order is not the reading order of the table at the top of
 * `AgentControls.tsx`, and that is deliberate: the two without a chip on the
 * row come first, because they are the reason anybody opens this. Measured in
 * the harness at 1280×900 — five sections are 1,634px of content in a 540px
 * panel, so what is at the top is what is found without scrolling, and putting
 * the two controls that are already one click away up there would spend that
 * space on the people who did not need the panel at all.
 */
export const MENU_CONTROLS: readonly ControlId[] = ['effort', 'fast', 'model', 'permission']

/**
 * Which of them *also* get a chip on the composer's own row, for the one-click
 * case.
 *
 * By how often a session reaches for the thing, not by how interesting it is:
 *
 *   Model       changes per task — "do this bit on Sonnet".            chip
 *   Permission  changes per phase — plan it, then let it edit.         chip
 *   Effort      set once, if ever, and then left alone.                panel
 *   Fast mode   rarer still, and usually cannot even be read (see      panel
 *               `unreadLabel`), so it spends most of its life
 *               reporting that it has nothing to report.
 *
 * A subset of `MENU_CONTROLS`, and `catalog.test.ts` asserts that — which is
 * the guard the pair of lists used to provide, moved to where it now belongs.
 * The consequence looks like duplication and is not: model and permission
 * appear twice, once as a chip and once as a section, and both are the same
 * control reading the same value and sending the same keystrokes. A menu that
 * is a complete inventory is worth a repeated row. A menu whose contents you
 * have to already know is not.
 */
export const PRIMARY_CONTROLS: readonly ControlId[] = ['model', 'permission']

/** The short name on the button. Sentence case; it is a name, not a heading. */
export function controlName(control: ControlId): string {
  if (control === 'model') return 'Model'
  if (control === 'effort') return 'Effort'
  if (control === 'fast') return 'Fast mode'
  return 'Permission'
}

/**
 * One line saying what the control does, for the folded panel where there is
 * room to say it.
 *
 * Each describes the *effect on this session*, not the option's merits: the
 * per-option hints already argue for themselves, and a description that also
 * recommends is a description nobody reads twice.
 */
export function describeControl(control: ControlId): string {
  if (control === 'model') return 'Which model answers in this session.'
  if (control === 'effort') return 'How much reasoning the model spends before it answers.'
  if (control === 'fast') return 'A quicker reply, drawn from your usage credits at a higher rate.'
  return 'What the agent may do without stopping to ask you first.'
}

/**
 * How far a change reaches — or `null` where we cannot say, in which case the
 * menu prints nothing rather than a comfortable guess.
 *
 * Permission is the only flat answer, and it is the CLI's own: it logs
 * "setMode … is session-scoped; not persisting as defaultMode".
 *
 * Model and effort are **branches**, not constants. The binary builds its
 * confirmation as `Set model to X` + (` and saved as your default for new
 * sessions` | ` for this session only`), and effort the same way in
 * parentheses. An earlier version of this function stated the first arm as
 * fact for both, which was wrong every time the CLI took the second — and
 * always wrong for ultracode, whose reply has no branch at all and is only
 * ever "(this session only)". So the menu now says the CLI decides, and
 * `applyControl` quotes the arm the CLI actually printed.
 *
 * Fast mode returns null: `/fast` announces on/off but says nothing about
 * scope, and the CLI keeps that flag outside `settings.json`, so any scope
 * sentence here would be invented.
 */
export function reachOf(control: ControlId): string | null {
  if (control === 'permission') return 'This session only'
  if (control === 'fast') return null
  return 'This session — and your default too, if the CLI says so when it confirms'
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
 * real was read the answer says so, because a control showing a confident value
 * it never read is the failure mode this feature exists to avoid.
 */
export function displayValue(reading: ControlReading | undefined, control?: ControlId): string {
  if (!reading || reading.label === null) return unreadLabel(control)
  return reading.label
}

/**
 * What a control says when nothing could be read.
 *
 * Fast mode gets its own word, and the reason is structural rather than
 * cosmetic. The other three resolve on essentially every machine: permission
 * and model are painted in the session's own footer, effort is persisted in
 * `settings.json`. Fast mode is in neither place — checked against the shipped
 * CLI, the only write it makes to `fastMode` in user settings is a *clear*,
 * and the enabled state lives in a store this app does not read — so the screen
 * is the sole source, and the CLI prints "Fast mode ON/OFF" only at the moment
 * it *changes*. A session that has never been told either way therefore has
 * nothing to report, for good, and "Unknown" beside three resolved siblings
 * reads as this app failing rather than as the CLI never having said.
 */
export function unreadLabel(control: ControlId | undefined): string {
  return control === 'fast' ? 'Not reported' : 'Unknown'
}

/**
 * The sentence under an unread control, or null where the plain source note
 * already covers it. Only fast mode has an explanation worth the line.
 */
export function unreadNote(control: ControlId | undefined): string | null {
  if (control !== 'fast') return null
  return 'The CLI announces fast mode only when it changes, and keeps the setting out of settings.json — so until this session says so, nothing here can. Pick On or Off to set it.'
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
