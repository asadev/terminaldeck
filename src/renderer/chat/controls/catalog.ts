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
  /**
   * A short tag under the label, for a fact about *this* account or session
   * that a reader cannot get from the row itself.
   *
   * ## It is not a description any more
   *
   * It was, on every row of two long lists — `Fable 5` under it *"Most capable
   * for your hardest and longest-running tasks"*, `High` under it
   * *"Comprehensive, with testing and docs"*, and eleven models each with a
   * grey line of their own. Rendered in a 340px sheet most of them wrapped to
   * two lines, and the panel became a page of prose with the actual choices
   * buried in it. Asad, in the same recording, looking at a list built the same
   * way: *"Why do we have all of this full list? … if I have ten like this, how
   * I will read all of them? It is a lot again, you know."* And the rule he
   * repeated most: *"don't put any single statement in anywhere… Let the smart
   * people use it. Smart people knows how it works."*
   *
   * `Fable 5` is the name of a model. A person choosing between it and `Sonnet
   * 5` in a coding agent knows what they are, and the CLI's own one-line gloss
   * is one keystroke away in the CLI itself.
   *
   * ## What survives, and the test it had to pass
   *
   * Two tags, and both are facts the row cannot state on its own:
   *
   *  - *"your account's default"* on a model — which is the whole of what the
   *    CLI's `Default (recommended)` row carried, folded onto the model it
   *    resolves to by `foldDefaultRow`. Delete it and the fold loses the thing
   *    it was folding.
   *  - *"this session only"* on `Ultracode` — every other effort can become the
   *    default for new sessions and that one cannot, which is a difference in
   *    what pressing the row *does*.
   *
   * A hint that would be true of any reader on any machine is a description and
   * does not belong here.
   */
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
  { id: 'xhigh', label: 'Extra high', hint: 'the default here' },
  // "this session only" is not a guess: the CLI has no other answer for
  // ultracode — `Set effort level to ultracode (this session only): xhigh +
  // dynamic workflow orchestration` is the whole of it, with no branch.
  { id: 'ultracode', label: 'Ultracode', hint: 'this session only' },
  { id: 'max', label: 'Max' },
  { id: 'high', label: 'High' },
  { id: 'medium', label: 'Medium' },
  { id: 'low', label: 'Low' },
  { id: 'auto', label: 'Auto' },
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
    /*
     * `row.note` — the CLI's own gloss, *"Best for everyday, complex tasks"* —
     * is read, kept on the row, and not drawn. Eleven of them down a 340px
     * panel is the wall of grey this cluster was told to stop printing; see
     * {@link ControlOption.hint}. What is left is the one thing the row cannot
     * say about itself, and it is why `foldDefaultRow` exists at all.
     */
    hint: row.recommended ? 'your account’s default' : undefined,
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
 * The two states fast mode can be in — a switch's positions, not a menu's rows.
 *
 * ## Why this stopped being a menu
 *
 * Asad, watching the bar: *"then here also now think we don't need, just one to
 * select is enough."* He is right, and the shape was the giveaway: a control
 * with exactly two states, one of which is always already in force, is a
 * toggle. Drawn as a picker it cost two clicks to do a one-click thing, and it
 * spent one of its two rows telling you what you were already doing. `Off` and
 * `On` survive as this list because the *values* are still real — `/fast off`
 * and `/fast on` are what gets typed, and `On`/`Off` are the words the CLI
 * itself reads back (see `readFast` in `src/main/agent-controls.ts`) — but
 * nothing renders them as a choice any more. `ControlToggle` reads them and
 * draws one control.
 *
 * ## The hint that was here, and why it is not any more
 *
 * The `On` row carried `Draws from your usage credits at a higher rate`. He
 * disputed it out loud: *"I don't know why it is saying it is extra chargeable
 * since it is not."*
 *
 * He is right that this repository never established it. The comparative — *a
 * higher rate* — was not measured, not quoted, and not cited anywhere; it was
 * written from the shape of the CLI's refusal rather than from anything the CLI
 * said. That is a claim about somebody's bill invented by this app, which is the
 * one kind of sentence it has no business composing.
 *
 * What the repository actually holds about the cost of fast mode is two lines,
 * both captured off `claude 2.1.234` on this machine, and neither of them is a
 * rate comparison:
 *
 *   `/fast on`  → `⎿  ↯ Fast mode ON · $10/$50 per Mtok`
 *                 (verbatim in `src/main/cli-screens.capture.json`, key `fastOn`)
 *   `/fast on`  → `⎿  Fast mode unavailable: Fast mode requires usage credits ·
 *                 /usage-credits to turn them on`   (on an account without them)
 *
 * Neither goes on screen from here, and that is deliberate rather than
 * squeamish. The price line is one account's price read once, so restating it as
 * a standing fact would be the same mistake one level down — a number nobody
 * measured *for this reader*. The refusal is not restated because it is already
 * shown verbatim at the moment it applies: `readFast` puts it on the reading as
 * `unavailableReason`, `blockedFor` in `SessionControls.tsx` prints it, and a
 * sentence pre-empting it would be this app guessing at an answer the CLI is
 * about to give in its own words.
 *
 * So the cost claim is gone rather than softened. If somebody wants a price on
 * this control, the honest way to get one is to quote the `↯ Fast mode ON ·
 * $10/$50 per Mtok` line the CLI prints at the moment of the change — which
 * `applyControl` currently discards in favour of `Fast mode On.` — and not to
 * write a sentence here.
 *
 * ## What is still worth saying, and it says it elsewhere
 *
 * The CLI's own description — *"Fast mode for Claude Code uses Claude Opus with
 * faster output (it does not downgrade to a smaller model). It can be toggled
 * with /fast and is available on Opus 5/4.8"* — and the line its model picker
 * prints under its rows, *"Switching to other models turns off fast mode"*. Both
 * live in {@link describeControl}, which is printed above this control wherever
 * there is room for a sentence. The second is the one that earns its words: turn
 * fast mode on, pick Sonnet, and you have silently turned it off again.
 */
export const FAST_OPTIONS: ControlOption[] = [
  { id: 'off', label: 'Off' },
  { id: 'on', label: 'On' },
]

export function optionsFor(control: ControlId): ControlOption[] {
  if (control === 'model') return MODEL_OPTIONS
  if (control === 'effort') return EFFORT_OPTIONS
  if (control === 'fast') return FAST_OPTIONS
  return PERMISSION_OPTIONS
}

/*
 * `PRIMARY_CONTROLS` and `MENU_CONTROLS` used to live here and they are gone.
 *
 * They were the composer's two lists — which controls got a chip on the chat
 * box's own row, and which ones lived in the Options panel behind it — and the
 * whole argument between them is worth keeping, because it has now been wrong
 * in both directions and the rule that settles it is not the midpoint.
 *
 * It began as `FOLDED_CONTROLS`: model and permission on the row, effort and
 * fast mode behind a button labelled "More", and the usage readout behind it
 * too. Nothing on screen said the word "effort", so there was no way to look
 * for it, and the report was *"all the options you have actually removed."* The
 * answer then was to make the panel the complete inventory of every control,
 * chip or no chip.
 *
 * That fixed the finding and created the opposite one, watching the app:
 * *"options is having all of the things that we already have here and there. So
 * let's keep everything separate rather than having everything on one page like
 * on options."* With the panel open, Model and Permission were on screen twice,
 * three centimetres apart, as a chip and as a section, each showing the same
 * value and sending the same keystrokes.
 *
 * The rule that satisfies both is **one home per control** — a control with a
 * chip is on the row and only there; a control without one is in the panel and
 * only there — and it is the rule the app still runs on. What changed is that
 * there is no longer a composer row for these two lists to describe: *"since we
 * have it on top we actually don't need them here… remove them from the chat
 * box side completely."* Every control that survives is drawn by
 * `shell/SessionControls.tsx`, from `CHROME_CONTROLS`, in the window's own bar.
 *
 * So the two lists had been describing a surface that does not exist for some
 * time, and `catalog.test.ts` was the only thing still reading them. Left in
 * place they would have become an outright lie the moment permission mode left
 * the chrome — a list called `PRIMARY_CONTROLS` naming a control that is on no
 * row anywhere. The invariant they carried has not been dropped with them: it
 * moved, whole, to `one-home.test.ts`, which reads `CHROME_CONTROLS` out of the
 * source and fails if a control ends up drawn in neither place. That is the
 * guard that matters — a control deleted from a list still leaves the app with
 * every one of its own tests passing.
 */

/*
 * `unsupportedProviderNote` used to live here and it is gone.
 *
 * It named the vendor twice — *"These work by typing Claude Code's own commands
 * into the session. Codex has its own…"* — on the controls bar of a session
 * running something else, which is exactly the complaint his review made:
 * *"you should not mention in any settings or any pop-up a specific tool or
 * LLM, because they can use some other also."* A screen that is showing one
 * agent while naming another is the sharpest form of it.
 *
 * `SessionControls.tsx` composes the sentence now, in the category's words
 * rather than the vendor's, beside the control it withdraws. Moved rather than
 * reworded here because the sentence belongs where the withdrawal is decided —
 * a note exported from a catalogue is a second place that has to be kept true.
 */


/** The short name on the button. Sentence case; it is a name, not a heading. */
export function controlName(control: ControlId): string {
  if (control === 'model') return 'Model'
  if (control === 'effort') return 'Effort'
  if (control === 'fast') return 'Fast mode'
  return 'Permission'
}

/**
 * One line saying what the control does.
 *
 * ## It is not printed on a panel any more
 *
 * It was, above every section of the folded controls sheet, and Asad — the
 * sentence he repeated more than any other on 2026-08-20 — *"don't put any
 * single statement in anywhere. Everywhere you are putting a lot of statements.
 * We don't need to give the statements. We want simplicity. Let the smart
 * people use it. Smart people knows how it works."*
 *
 * `Which model answers in this session.` over a list of models is the exact
 * shape he was objecting to: a sentence that tells a reader what the heading
 * already told them. So the sheet prints none of these, and {@link controlNote}
 * decides which of them is still worth reaching — behind the ⓘ, which is the
 * one place he allowed an explanation to live: *"if somewhere it's very
 * required, give the i icon like other ones, information icon in the settings,
 * same way."*
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
  //
  // It used to end `…at a higher draw on your usage credits`, and that clause is
  // deleted rather than reworded. Nothing in this repository measures a rate,
  // let alone a *higher* one, and Asad said so watching it: *"I don't know why
  // it is saying it is extra chargeable since it is not."* The whole account of
  // what is and is not known about the cost is at {@link FAST_OPTIONS}; the
  // short version is that the CLI states its own price at the moment of the
  // change and refuses in its own words when the account cannot pay it, and
  // both of those are better than a sentence composed here in advance.
  //
  // The word `Opus` went with it, and that is a second rule being obeyed rather
  // than a casualty of the first. This sentence is drawn on a bar that also sits
  // over Codex and Gemini sessions — drawn back, carrying a refusal, but drawn —
  // and *"you should not mention in any settings or any pop-up a specific tool
  // or LLM, because they can use some other also."* `The same model` says the
  // one thing the CLI's description is actually asserting, which is that fast
  // mode does not swap you onto a smaller one, and it says it without naming
  // anybody's model on a screen that may be showing somebody else's agent.
  if (control === 'fast')
    return 'The same model, answering faster. Switching to another model turns it off.'
  return 'What the agent may do without stopping to ask you first.'
}

/**
 * Which controls still owe the reader a sentence, and never on screen.
 *
 * The standing ⓘ beside a section's heading, or `null` for no dot at all — and
 * `null` is the answer for almost everything, which is the point. A dot is a
 * mark on the line saying *there is more here*, so putting one on every section
 * is the paragraph coming back one glyph at a time.
 *
 * Model and effort get nothing. `Which model answers in this session.` above a
 * list of model names, and `How much reasoning the model spends before it
 * answers.` above `Extra high / Max / High / Medium / Low`, are the app telling
 * a reader what the heading and the rows have already told them twice.
 *
 * Fast mode keeps one, and it is the second half of its description that earns
 * it: *"Switching to another model turns it off."* That is not a definition, it
 * is a consequence, and it is invisible — turn fast mode on, pick Sonnet from
 * the section directly above, and you have silently turned it off again with
 * nothing on screen having changed to say so. A reader cannot deduce it, which
 * is the test this function applies.
 */
export function controlNote(control: ControlId): string | null {
  return control === 'fast' ? describeControl(control) : null
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
 * The model name at chip length: the model, and its window when that is what
 * distinguishes it.
 *
 * ## The complaint, and why an ellipsis was the wrong answer to it
 *
 * Asad, reading the bar: *"where it is showing model with Opus 5 with 1M, then
 * dot dot dot — only showing Opus 5 is enough. They can see it inside the
 * dropdown, they don't need to see this long thing with three dots."*
 *
 * `Opus 5 with 1M context` is 22 characters against the chip's 14, so it landed
 * as `Opus 5 with 1M…`. An ellipsis on a chip whose whole job is to name one
 * short thing is the label being wrong rather than the bar being narrow: the
 * name is what needs shortening, and the place with room for the long one is the
 * menu, which the chip opens and which still prints every row in full.
 *
 * ## What must survive the shortening
 *
 * The long-context marker, and it is the whole difficulty. The picker offers
 * `Opus 5` and `Opus 5 with 1M context` as separate rows — genuinely different
 * windows — so a shortening that returns `Opus 5` for both would leave two
 * selections that look identical on the bar with nothing to tell them apart.
 * `1M` is kept for that reason and only that reason: `Opus 5` and `Opus 5 1M`
 * are nine characters at the longest, both fit the chip without an ellipsis, and
 * the chip's `title` carries whichever full name it came from.
 *
 * The inputs are the four spellings listed on {@link modelKey} — the CLI's
 * confirmation, its picker row, `labelModelId` off a transcript, and its welcome
 * panel — plus `Opus in plan mode, else Sonnet`, the one row that names a policy
 * rather than a model and is the only other row too long for the chip.
 */
export function shortModelLabel(label: string): string {
  const text = label.trim()
  // The policy row. `Opus Plan` is the picker's own name for it, and the clause
  // it drops — "else Sonnet" — is the half a reader can already see in the menu.
  const plan = /^(\S+) in plan mode/i.exec(text)
  if (plan) return `${plan[1]} Plan`
  const long = /1m/i.test(text)
  const name = text
    .replace(/\((?:default|recommended)\)/gi, '')
    .replace(/\(1m context\)|with 1m context|·\s*1m/gi, '')
    .replace(/\s+/g, ' ')
    .trim()
  return long ? `${name} 1M` : name
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
