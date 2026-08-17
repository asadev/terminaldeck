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
 * Which controls get a chip on the composer's own row, in reach at one click.
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
 * These two are the row, and — since the Options panel stopped repeating them,
 * see {@link MENU_CONTROLS} — they are the *only* place either can be changed.
 * `AgentControls` draws this list under exactly the condition under which it
 * draws the panel's sections (`usable`), so neither can be on screen without
 * the other: there is no state in which a control here has no home.
 */
export const PRIMARY_CONTROLS: readonly ControlId[] = ['model', 'permission']

/**
 * What the Options panel lists: the controls that have **no other home**.
 *
 * This list has now been wrong in both directions, and both reports are worth
 * keeping because the rule that satisfies them is not the midpoint between
 * them.
 *
 * It began as a second list called `FOLDED_CONTROLS`: model and permission on
 * the row, effort and fast mode behind a button labelled "More", and the usage
 * readout behind it too. Nothing on screen said the word "effort", so there was
 * no way to look for it, and the report was *"all the options you have actually
 * removed."* The answer then was to make the panel the complete inventory of
 * every control, chip or no chip.
 *
 * That fixed the finding and created the opposite one, reported watching the
 * app: *"options is having all of the things that we already have here and
 * there. So let's keep everything separate rather than having everything on one
 * page like on options."* And he is right — with the panel open, Model and
 * Permission were on screen twice, three centimetres apart, as a chip and as a
 * section, each showing the same value and sending the same keystrokes.
 *
 * The rule that satisfies both is neither "everything" nor "the leftovers". It
 * is **one home per control**:
 *
 *   - a control with a chip on the row is on the row, and only there;
 *   - a control without one is in the panel, and only there.
 *
 * The old regression cannot come back through this door, and the reason is
 * worth being precise about rather than trusting. What made "More" unfindable
 * was that nothing on screen named what it held. Nothing on screen still names
 * what is in *this* panel either — except that the button's own hover label is
 * built from this very list (`optionsLabel` in `AgentControls.tsx`), so it
 * reads "Effort and fast mode", which is precisely the naming "More" lacked.
 * And the two controls dropped from the list did not go behind anything: they
 * are chips, with their names printed on them, beside the button. Nothing moved
 * further away; two things stopped being said twice.
 *
 * `catalog.test.ts` pins that this list and `PRIMARY_CONTROLS` partition the
 * four controls — every one in exactly one of them. That is the guard the old
 * "the panel contains everything" assertion was providing, restated as the rule
 * that is actually wanted: a control deleted from both lists still leaves the
 * app with all of its own tests passing, and that is what these two files are
 * here to catch.
 */
export const MENU_CONTROLS: readonly ControlId[] = ['effort', 'fast']

/**
 * Why these controls are withheld from an agent CLI that is not Claude Code, or
 * null when the provider is one they work on.
 *
 * ## Why there is a sentence here at all
 *
 * Every option in this file is a Claude Code command, and every value the
 * pickers display is read back out of Claude Code's own screen or its
 * `settings.json`. Neither half generalises to another CLI. Leaving the pickers
 * on for a Codex or Gemini session would give it five model aliases that mean
 * nothing there, wired to a `/model sonnet` nobody has checked it understands,
 * showing an effort level read out of a file it never wrote — a dead control
 * three ways over, which is the exact failure class this composer keeps being
 * audited for.
 *
 * ## Why the sentence says "not established" rather than "not possible"
 *
 * Because that is what was found. Both were looked at on the machine this was
 * written on and neither could be driven: the Codex install is broken (its
 * vendored binary is missing) and the Gemini CLI stops on an unanswered
 * authentication picker. So this build has no evidence either way, and claiming
 * they *cannot* change a model at runtime would be inventing a fact in order to
 * sound more final. Saying what is true costs nothing and stays true when
 * somebody comes back to add support.
 *
 * `shell` is not here: it has its own sentence, because "there is no model in a
 * shell" and "this build has not learned this CLI's commands" are different
 * things and collapsing them would make the shell case sound like a gap.
 */
export function unsupportedProviderNote(provider: string | undefined): string | null {
  if (provider !== 'codex' && provider !== 'gemini') return null
  const name = provider === 'codex' ? 'Codex' : 'Gemini'
  return `These work by typing Claude Code’s own commands into the session. ${name} has its own, and this build has not been shown what they are — so nothing is offered here rather than a button that types the wrong thing.`
}

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
 * ## Two different silences, and only one of them is a failure
 *
 * "Unknown" is the right word for a read that *should* have worked and did not
 * — the model is painted in the session's own footer and recoverable from the
 * transcript, effort is persisted in `settings.json`, so nothing coming back
 * from either means something went wrong and the word should say so.
 *
 * Fast mode and permission mode are a different case. For both there are
 * states in which nothing has ever said, and no amount of waiting changes it.
 *
 *  - **Fast mode.** Checked against the shipped CLI, the only write it makes to
 *    `fastMode` in user settings is a *clear*, and the enabled state lives in a
 *    store this app does not read — so the screen is the sole source, and the
 *    CLI prints "Fast mode ON/OFF" only at the moment it *changes*.
 *
 *  - **Permission mode.** Asad, watching the composer: the model "eventually
 *    resolves", permission "never does". He was right, and it was not slow — it
 *    was unreachable. The footer lines this app matches are the confirmations
 *    the CLI prints *on entering* a mode, so a session nobody has pressed
 *    shift+tab in has nothing on screen to read at all. That now falls back to
 *    `permissions.defaultMode` in the settings files the CLI itself reads (see
 *    `readPermissionDefault` in `src/main/agent-controls.ts`), which settles it
 *    on any machine that has set one. What is left here is the genuinely
 *    unknowable remainder: no confirmation on screen and no default written
 *    anywhere. The CLI has a built-in default in that case and this app has not
 *    been told what it is, and inventing one would be a claim about what an
 *    agent is allowed to do — the last thing in this window to guess at.
 *
 * So both say the same thing, and it is what actually happened: nothing
 * reported it. One word for one situation, and "Unknown" left meaning "a read
 * failed" rather than doing double duty for "there was nothing to read".
 */
export function unreadLabel(control: ControlId | undefined): string {
  return control === 'fast' || control === 'permission' ? 'Not reported' : 'Unknown'
}

/**
 * The sentence under an unread control, or null where the plain source note
 * already covers it.
 *
 * Both controls that can be honestly silent get one, because in both cases the
 * reader's next question is the same — why not, and what do I do about it — and
 * so is the answer: pick one, and the session will say.
 */
export function unreadNote(control: ControlId | undefined): string | null {
  if (control === 'fast') {
    return 'The CLI announces fast mode only when it changes, and keeps the setting out of settings.json — so until this session says so, nothing here can. Pick On or Off to set it.'
  }
  if (control === 'permission') {
    return 'Claude prints the permission mode only when it changes, and no default is set in your Claude settings — so this session has not said which one it is in. Pick one and it will.'
  }
  return null
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
