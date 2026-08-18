/**
 * What each control is allowed to offer, and how to describe what it does.
 *
 * Kept away from React because the interesting part of this feature is not the
 * menu — it is the claim each option makes about the CLI. Every option below
 * corresponds to something typed at the real `claude` binary on this machine,
 * and the `applies` field records how far the change reaches, which is the one
 * thing a user cannot find out by looking.
 */

import {
  foldDefaultRow,
  FALLBACK_MODELS,
  PREVIOUS_MODELS,
  type ModelRow,
} from '../../../shared/model-catalog'

export type ControlId = 'model' | 'effort' | 'fast' | 'permission'

/** Where a reading came from. Mirrors `ValueSource` in `src/main/agent-controls.ts`. */
export type ValueSource = 'screen' | 'transcript' | 'settings' | 'env'

export interface ControlOption {
  id: string
  label: string
  /** One line under the label. Says what it does, not that it is recommended. */
  hint?: string
  /**
   * A caption printed above this option, starting a run of rows that are a
   * different kind of claim from the ones before them.
   *
   * There is exactly one of these and it earns its existence. The model menu
   * ends with names the CLI's picker deliberately does *not* list — `Opus 4.8`,
   * `Sonnet 4.6` — which `/model` still accepts but which an account may not be
   * entitled to. Run together with the picker's own rows they read as one list
   * where half the entries are guaranteed and half are not, with nothing on
   * screen saying which is which. That was visible the first time it was drawn
   * and is the reason this field exists rather than a comment about it.
   */
  group?: string
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
 * The effort a session gets when nobody has ever chosen one.
 *
 * Asad: *"effort defaults to extra-high, and a change sticks."*
 *
 * It is a real default rather than a label: `useSessionControls` types
 * `/effort xhigh` into a session that reports **no** effort from any source —
 * not the screen, not the transcript, not `settings.json`, not the environment
 * — which is the state of a machine on which nobody has ever set one. The CLI
 * then saves it as the default for new sessions, so this happens once on a
 * machine and never again. A session that already has an effort is left exactly
 * as it is, because overriding somebody's setting is not a default.
 *
 * Stated here rather than in the hook so that the value the app applies and the
 * value the menu marks are one fact. Two spellings of a default is how a menu
 * comes to point at a row the app is not actually setting.
 */
export const DEFAULT_EFFORT = 'xhigh'

/**
 * Effort levels, quoted from the CLI's own rejection of a bad argument:
 * "Valid options are: low, medium, high, xhigh, max, ultracode, auto".
 *
 * ## The order, which is a decision and not the CLI's
 *
 * Extra high is first because it is what this app sets when nothing is set —
 * see {@link DEFAULT_EFFORT} — and the first row of a menu is read as the
 * default whether or not it was meant to be. It used to be `Auto`, which is not
 * this app's default and never was: `auto` means *clear the setting and let the
 * model decide*, which is the one option that undoes the default rather than
 * being it. It reads better at the far end, next to the other deliberate
 * choices, where it says what it actually is.
 *
 * The rest run from the deepest to the shallowest, so the list descends from
 * the row above it instead of restarting. `Ultracode` sits with `Max` because
 * both are "more than extra high", and `Auto` is last because it is the only
 * row that is a *withdrawal* of a choice.
 */
export const EFFORT_OPTIONS: ControlOption[] = [
  { id: 'xhigh', label: 'Extra high', hint: 'Deeper reasoning than high · the default here' },
  // "this session only" is not a guess: the CLI has no other answer for
  // ultracode — `Set effort level to ultracode (this session only): xhigh +
  // dynamic workflow orchestration` is the whole of it, with no branch.
  { id: 'ultracode', label: 'Ultracode', hint: 'Extra high plus dynamic workflows · this session only' },
  { id: 'max', label: 'Max', hint: 'Deepest reasoning available' },
  { id: 'high', label: 'High', hint: 'Comprehensive, with testing and docs' },
  { id: 'medium', label: 'Medium', hint: 'Standard implementation and testing' },
  { id: 'low', label: 'Low', hint: 'Quick, minimal overhead' },
  { id: 'auto', label: 'Auto', hint: "Clear it, and let the model use its own default" },
]

/**
 * The models on offer, built from the CLI's own picker rather than written here.
 *
 * ## What was wrong with the list this replaced
 *
 * It was five hand-typed rows — `Default`, `Opus`, `Fable`, `Sonnet`, `Haiku` —
 * and Asad named both of its faults in one breath:
 *
 *   > *"They are just very few, not all of them. And Opus 4 should be Opus 5.
 *   > Opus 4-point-something is available. They should be listed here also… There
 *   > are more models — see Sonnet 4.6, to Fable 5 — so we should have all of
 *   > them."*
 *
 * A row reading `Opus` cannot answer "am I on Opus 5 or Opus 4.8", which is the
 * question he was asking; and a list written by hand is right for exactly as
 * long as it takes Anthropic to ship something. So the rows now carry the model
 * each resolves to, and the list itself is {@link ModelRow}s from
 * `shared/model-catalog.ts` — the same module the main process fills by reading
 * the session's own `/model` picker. What is written down is only the fallback
 * for the moment before a session has been asked.
 *
 * `Default` is gone as a choice, which is the second thing he asked for:
 *
 *   > *"Unknown should not be there, it should be already selected. Default, I
 *   > think, is nothing, because in Claude you don't see anything default — it
 *   > just says automatically unselected ones, but not as a separate choice."*
 *
 * `foldDefaultRow` does the removing, and moves the fact `Default` was carrying
 * — which model the account prefers — onto that model's own row as a note.
 */
export function modelOptions(rows: readonly ModelRow[] = FALLBACK_MODELS): ControlOption[] {
  return foldDefaultRow(rows).map((row) => ({
    id: row.alias,
    // The name and the model are usually the same word plus a number
    // (`Sonnet` / `Sonnet 5`), and printing both would read as a stutter. Where
    // they differ — `Opus (1M context)` / `Opus 5 with 1M context` — the model
    // is the more useful of the two, so it wins outright.
    label: row.model,
    hint: [row.note, row.recommended ? 'your account’s default' : ''].filter(Boolean).join(' · ') || undefined,
  }))
}

/**
 * The models the picker hides but `/model` still accepts, under their own
 * heading.
 *
 * Kept separate from {@link modelOptions} because they are a weaker claim: the
 * picker's rows are what this account is offered today, while these are names
 * the CLI will still parse and may still refuse. Each was typed at
 * `claude 2.1.234` and accepted — the account-level refusal, when it comes,
 * comes from the CLI in its own words.
 */
export function previousModelOptions(): ControlOption[] {
  return PREVIOUS_MODELS.map((row, index) => ({
    id: row.alias,
    label: row.model,
    // Only the first row carries the caption; the rest inherit it by sitting
    // under it. See {@link ControlOption.group}.
    group: index === 0 ? 'Earlier models' : undefined,
  }))
}

/** The static list, for the surfaces that have not asked a session yet. */
export const MODEL_OPTIONS: ControlOption[] = modelOptions()

/**
 * Fast mode, and the two facts about it that decide whether to touch it.
 *
 * Both come off the shipped binary rather than out of a help page. Its own
 * description reads *"Fast mode for Claude Code uses Claude Opus with faster
 * output (it does not downgrade to a smaller model). It can be toggled with
 * /fast and is available on Opus 5/4.8"*, and the model picker prints
 * *"Switching to other models turns off fast mode"* under its rows. So the two
 * things worth saying here are what it costs and what it constrains — the
 * second especially, because a user who turns it on and then picks Sonnet has
 * silently turned it off again and nothing else on screen would say so.
 */
export const FAST_OPTIONS: ControlOption[] = [
  { id: 'off', label: 'Off' },
  // The hint is the *cost*, and only the cost. What fast mode is belongs to
  // `describeControl`, which is printed directly above these two rows in the
  // panel — saying it in both places put the same sentence on screen twice,
  // three centimetres apart, which was visible the moment it was drawn.
  { id: 'on', label: 'On', hint: 'Draws from your usage credits at a higher rate' },
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
  // Both halves of this sentence are the CLI's own. Its description of the
  // feature: "uses Claude Opus with faster output (it does not downgrade to a
  // smaller model)… available on Opus 5/4.8". Its model picker, under the rows:
  // "Switching to other models turns off fast mode." The second half is the one
  // worth the words — without it, somebody turns fast mode on, picks Sonnet,
  // and has silently turned it off again.
  if (control === 'fast')
    return 'Opus, answering faster, at a higher draw on your usage credits. Switching to another model turns it off.'
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
 * Fast mode used to return null, on the grounds that nothing said what its
 * scope was. Driving it settled that: fast mode was turned on, the `claude`
 * process was killed, and a **brand-new** one booted with the `↯` still drawn in
 * its status rule. It outlives the session, so the sentence is no longer a
 * guess — and it is worth saying, because "on until I turn it off" and "on for
 * this session" are very different things to leave switched on by accident.
 */
export function reachOf(control: ControlId): string | null {
  if (control === 'permission') return 'This session only'
  if (control === 'fast') return 'Stays on until you turn it off — new sessions too'
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
 * The **model** should now never reach this function at all, and that is the
 * point of `readControls`' four-source chain: a screen confirmation, then the
 * transcript, then the CLI's welcome panel, then `settings.json`. Asad's ask was
 * *"Unknown should not be there, it should be already selected"*, and the only
 * way to satisfy it honestly is to make the read succeed rather than to invent a
 * label when it fails. The word stays here for the case that is left — a session
 * whose screen cannot be read at all — because printing a model name for a
 * session nobody could look at would be the fake this control exists to avoid.
 *
 * Permission mode is a different case. There are states in which nothing has
 * ever said, and no amount of waiting changes it.
 *
 *  - **Fast mode** used to be listed here beside it, on the grounds that the CLI
 *    "prints Fast mode ON/OFF only at the moment it changes". Driving the
 *    shipped binary showed that is not the whole truth: it also draws a `↯` in
 *    the status rule above the command line and leaves it there for as long as
 *    fast mode is on, across new sessions. So fast mode is now read on every
 *    screen and no longer reports silence — see `readFastIndicator` in
 *    `src/main/agent-controls.ts`, and `agent-controls.live.test.ts`, which
 *    reads both states out of captures of the real thing.
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
 * So permission says what actually happened — nothing reported it — and
 * "Unknown" is left meaning "a read failed" rather than doing double duty for
 * "there was nothing to read".
 */
export function unreadLabel(control: ControlId | undefined): string {
  return control === 'permission' ? 'Not reported' : 'Unknown'
}

/**
 * The sentence under an unread control, or null where the plain source note
 * already covers it.
 *
 * Permission is the one control left that can be honestly silent, and the
 * reader's next question is always the same — why not, and what do I do about
 * it — so the sentence answers both: pick one, and the session will say.
 *
 * Fast mode had one of these and no longer needs it. It said "the CLI announces
 * fast mode only when it changes… until this session says so, nothing here
 * can", which was written from reading the binary's strings and was wrong when
 * the binary was actually driven: the `↯` in the status rule reports the state
 * continuously. A note explaining why a control cannot answer, printed under a
 * control that can, is worse than no note.
 */
export function unreadNote(control: ControlId | undefined): string | null {
  if (control === 'permission') {
    return 'Claude prints the permission mode only when it changes, and no default is set in your Claude settings — so this session has not said which one it is in. Pick one and it will.'
  }
  return null
}

/**
 * A model name reduced to the two things that decide whether two names are the
 * same model: which model, and which context window.
 *
 * The same model arrives spelled four ways, and all four are real readings this
 * app takes:
 *
 *   `Opus 5 (1M context) (default)`  the CLI's own confirmation line
 *   `Opus 5 with 1M context`         a row of the CLI's own picker
 *   `Opus 5 · 1M`                    `labelModelId`, from the transcript
 *   `Opus 5`                         the CLI's welcome panel
 *
 * The long-context marker is the part that must survive the reduction: `Opus 5`
 * and `Opus 5 (1M context)` are genuinely different — different windows,
 * different money — and collapsing them would tick the wrong row on a list that
 * offers both, which is precisely the list this app now offers. Everything else
 * (the `(default)` marker, the punctuation, the word "with") is spelling.
 */
function modelKey(text: string): { name: string; long: boolean } {
  const lower = text.toLowerCase()
  const long = /1m/.test(lower)
  const name = lower
    .replace(/\((?:default|recommended)\)/g, '')
    .replace(/\(1m context\)|with 1m context|·\s*1m/g, '')
    .replace(/[^a-z0-9. ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return { name, long }
}

/**
 * True when the menu should mark this option as the one currently in force.
 *
 * Effort, fast mode and permission read back as the exact id that was sent, so
 * those are a straight comparison, and that comparison is tried first for
 * everything — the model reads back as its own alias when the source is
 * `settings.json`.
 *
 * The model otherwise comes back as a *display name* rather than an id, and
 * every row of the menu is now a display name too (`Opus 5`, `Sonnet 5`), so the
 * two are compared after both have been through {@link modelKey}. The previous
 * version compared the row's label against the front of the reading — which
 * worked only while the rows were bare family words, and stopped the moment they
 * started naming versions. That change is the entire point of the new list, so
 * this had to move with it.
 *
 * A tick is a claim, so an unreadable value ticks nothing.
 */
export function isCurrent(reading: ControlReading | undefined, option: ControlOption): boolean {
  if (!reading || reading.value === null) return false
  if (reading.value === option.id) return true
  const shown = reading.label ?? ''
  if (shown.trim() === '') return false
  const read = modelKey(shown)
  const offered = modelKey(option.label)
  return read.name !== '' && read.name === offered.name && read.long === offered.long
}
