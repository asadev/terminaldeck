import { describe, expect, it } from 'vitest'
import {
  controlName,
  describeControl,
  displayValue,
  unreadLabel,
  unreadNote,
  EFFORT_OPTIONS,
  FAST_OPTIONS,
  isCurrent,
  MODEL_OPTIONS,
  modelOptions,
  optionsFor,
  PERMISSION_OPTIONS,
  reachOf,
  shortModelLabel,
  sourceNote,
  type ControlId,
  type ControlReading,
} from './catalog'

/** Every control the app knows about. The lists below must partition this. */
const ALL: ControlId[] = ['model', 'effort', 'fast', 'permission']

describe('what the row is allowed to offer', () => {
  it('offers only the effort levels the CLI listed when it rejected a bad one', () => {
    // "Invalid argument: nosuchlevel. Valid options are: low, medium, high,
    // xhigh, max, ultracode, auto" — typed at the real binary.
    expect(EFFORT_OPTIONS.map((option) => option.id).sort()).toEqual(
      ['auto', 'high', 'low', 'max', 'medium', 'ultracode', 'xhigh'].sort(),
    )
  })

  it('does not offer dontAsk, which no running session can reach', () => {
    // `--permission-mode` accepts it, but it never appeared in the shift+tab
    // cycle, so there is no keystroke that would select it.
    expect(PERMISSION_OPTIONS.map((option) => option.id)).not.toContain('dontAsk')
  })

  /*
   * This test used to require a `Default` row, and it was right to: `/model
   * default` answered "Opus 5 (1M context)" while `/model opus` answered "Opus
   * 5", so collapsing the two would silently have changed the context window.
   *
   * What has changed is that the two context windows are now *both on the list
   * under their own names*. The real picker offers `Opus (1M context)` and
   * `Opus` as separate rows — captured in `cli-screens.capture.json` — so the
   * distinction that made `Default` necessary is carried by rows that say which
   * model they are, and `Default` is left doing nothing but pointing at one of
   * them. Which is what Asad saw: *"Default, I think, is nothing… in Claude you
   * don't see anything default."*
   *
   * So the assertion is inverted rather than deleted. The thing that must not
   * regress is the distinction, not the row.
   */
  it('offers both context windows by name, and no Default row', () => {
    const ids = MODEL_OPTIONS.map((option) => option.id)
    expect(ids).toContain('opus[1m]')
    expect(ids).toContain('opus')
    expect(ids).not.toContain('default')
  })

  it('names a version on every model row', () => {
    // "Opus 4 should be Opus 5" — a row labelled with a bare family name cannot
    // answer that question, which is what made the old list unreadable to him.
    for (const option of MODEL_OPTIONS) {
      if (option.id === 'opusplan') continue // "Opus in plan mode, else Sonnet"
      expect(option.label, option.id).toMatch(/\d/)
    }
  })

  it('builds its rows from a picker the CLI drew, when it has one', () => {
    const live = modelOptions([
      { alias: 'sonnet', name: 'Sonnet', model: 'Sonnet 6', note: 'the new one', current: true, recommended: false },
      { alias: 'haiku', name: 'Haiku', model: 'Haiku 5', note: '', current: false, recommended: true },
    ])
    expect(live.map((option) => option.label)).toEqual(['Sonnet 6', 'Haiku 5'])
    expect(live[1].hint).toBe('your account’s default')
  })

  it('routes each control to its own option list', () => {
    expect(optionsFor('model')).toBe(MODEL_OPTIONS)
    expect(optionsFor('effort')).toBe(EFFORT_OPTIONS)
    expect(optionsFor('permission')).toBe(PERMISSION_OPTIONS)
  })

  /*
   * Fast mode is a switch, and both halves of that sentence are pinned here.
   *
   * `SessionControls.tsx` decides which shape to draw by asking whether a
   * control has exactly two options — deliberately, so that this file stays the
   * one place that knows which control is two-state. That makes the *length* of
   * this list load-bearing rather than incidental: a third row added here would
   * silently turn the switch back into a picker, which is the shape Asad asked
   * to be rid of.
   */
  it('gives fast mode exactly two states, in the order a switch reads them', () => {
    expect(FAST_OPTIONS.map((option) => option.id)).toEqual(['off', 'on'])
  })

  it('makes no claim about what fast mode costs, because none was ever measured', () => {
    /*
     * The `On` row used to carry `Draws from your usage credits at a higher
     * rate`, and Asad disputed it watching the app: *"I don't know why it is
     * saying it is extra chargeable since it is not."*
     *
     * He was right that nothing here established it. The comparative was not
     * measured, quoted or cited anywhere in this repository. What the repo does
     * hold — `↯ Fast mode ON · $10/$50 per Mtok` in `cli-screens.capture.json`,
     * and the CLI's own `Fast mode requires usage credits` refusal — is the
     * CLI's, arrives from the CLI at the moment it applies, and is not restated
     * here.
     *
     * Asserted as a property of every string this control shows rather than as
     * "that one sentence is gone", because the failure is a *kind* of sentence:
     * an app-authored guess about somebody's bill. A reworded one would pass a
     * check written the other way.
     */
    const said = [describeControl('fast'), ...FAST_OPTIONS.map((option) => option.hint ?? '')].join(' ')
    expect(said).not.toMatch(/higher rate|higher draw|extra charge|costs more/i)
    expect(said).not.toMatch(/\$\d|per Mtok/i)
  })

  it('does not name a vendor’s model in a sentence drawn over any agent', () => {
    /*
     * *"you should not mention in any settings or any pop-up a specific tool or
     * LLM, because they can use some other also."* This description is printed
     * on a bar that is also drawn — drawn back, carrying a refusal, but drawn —
     * over Codex and Gemini sessions, so it is a shared screen by that rule.
     * It used to open with the word `Opus`.
     */
    expect(describeControl('fast')).not.toMatch(/opus|claude|sonnet|haiku|gpt|gemini|codex/i)
  })
})

/*
 * `PRIMARY_CONTROLS` and `MENU_CONTROLS` were asserted here and they are gone.
 *
 * Four checks: that the row held model and permission, that the two lists
 * partitioned the four controls, that neither repeated the other, and that the
 * panel held more than one thing. All four described the *composer's* control
 * row, which no longer exists — every control that survives is drawn by
 * `shell/SessionControls.tsx` from `CHROME_CONTROLS`, in the window's own bar.
 *
 * The half of it that was load-bearing is the partition, and specifically one
 * direction of the partition: that nothing ends up in *neither* list, which is
 * how a control leaves the app while all of its own tests keep passing. That
 * check has not been dropped. It lives in `one-home.test.ts`, which reads
 * `CHROME_CONTROLS` out of the source — the list that is actually rendered —
 * rather than out of a pair of exports that had stopped describing any surface.
 * Asserting a partition of two dead lists would have gone on passing while the
 * bar drew whatever it liked, which is precisely the failure the original
 * assertion was written to catch.
 */

describe('what the controls are named and described as', () => {
  it('names and describes every control, so none is a bare icon', () => {
    for (const control of ALL) {
      expect(controlName(control), control).not.toBe('')
      // A description is a sentence, not a label repeated in lower case.
      expect(describeControl(control), control).toMatch(/\.$/)
      expect(describeControl(control).length, control).toBeGreaterThan(controlName(control).length)
    }
  })
})

describe('how far a change reaches', () => {
  it('states the one scope the CLI states flatly', () => {
    // "setMode … is session-scoped; not persisting as defaultMode" — the CLI's
    // own words, and it has no other answer for a runtime mode change.
    expect(reachOf('permission')).toMatch(/session only/i)
  })

  it('does not promise "saved as your default" for the two controls that branch', () => {
    // The binary composes `Set model to X` + (" and saved as your default for
    // new sessions" | " for this session only"), and effort the same way —
    // ultracode only ever takes the session-only arm. Asserting the first arm
    // was a scope claim nothing had read.
    for (const control of ['model', 'effort'] as const) {
      const reach = reachOf(control)
      expect(reach).not.toBeNull()
      expect(reach).not.toMatch(/^This session, and saved/i)
      expect(reach).toMatch(/if the CLI says so/i)
    }
  })

  /*
   * This asserted `null` — "fast mode announces no scope, so say nothing" —
   * until the scope was measured instead of reasoned about. Fast mode was
   * turned on, the `claude` process was killed, and a brand-new one booted with
   * the `↯` still in its status rule. It survives the session, so there is a
   * scope to state and it is worth stating: "on until I turn it off" and "on
   * for this session" are very different things to leave switched on by
   * accident, whatever they cost.
   *
   * That last clause used to read "leaving a higher credit draw switched on by
   * accident", which was the same unmeasured cost claim `FAST_OPTIONS` carried
   * on its `On` row and which Asad disputed — *"I don't know why it is saying it
   * is extra chargeable since it is not."* The scope is measured; the rate never
   * was.
   */
  it('says that fast mode outlives the session, because it was watched doing so', () => {
    expect(reachOf('fast')).toMatch(/until you turn it off/i)
  })
})

describe('never showing a value that was not read', () => {
  it('says Unknown rather than picking something plausible', () => {
    expect(displayValue({ value: null, label: null, source: null })).toBe('Unknown')
    expect(displayValue(undefined)).toBe('Unknown')
  })

  /**
   * Asad, watching the composer: the model "eventually resolves", permission
   * "never does". It was not slow — the footer only prints the mode when it
   * *changes*, so a session nobody had cycled had no source at all, and the
   * control sat on "Unknown" for its whole life.
   *
   * `readPermissionDefault` in the main process now settles it from the same
   * settings files the CLI reads. What survives here is the case where nothing
   * anywhere has said, and the word for that is not "Unknown" — "Unknown" in
   * this row means a read failed, and nothing failed.
   */
  it('says a silent permission mode was not reported, not that it is unknown', () => {
    expect(displayValue({ value: null, label: null, source: null }, 'permission')).toBe(
      'Not reported',
    )
    expect(displayValue(undefined, 'permission')).toBe('Not reported')
    expect(unreadLabel('permission')).toBe('Not reported')
  })

  it('keeps Unknown for the two controls where silence really is a failure', () => {
    // Model is painted in the footer *and* recoverable from the transcript;
    // effort is persisted. Neither answering means something went wrong.
    expect(unreadLabel('model')).toBe('Unknown')
    expect(unreadLabel('effort')).toBe('Unknown')
  })

  it('explains a silent permission mode and says what to do about it', () => {
    const note = unreadNote('permission')
    expect(note).not.toBeNull()
    expect(note).toMatch(/only when it changes/i)
    expect(note).toMatch(/pick one/i)
  })

  it('names the source so a read value and an assumed one are told apart', () => {
    expect(sourceNote('screen')).toMatch(/this session/i)
    expect(sourceNote('transcript')).toMatch(/last reply/i)
    expect(sourceNote('settings')).toMatch(/settings/i)
    expect(sourceNote('env')).toMatch(/CLAUDE_CODE_EFFORT_LEVEL/)
    expect(sourceNote(null)).toBe('not known')
  })
})

describe('which option gets the tick', () => {
  const reading = (value: string | null, label: string | null): ControlReading => ({
    value,
    label,
    source: value === null ? null : 'screen',
  })

  it('ticks nothing when the value is unknown — a tick is a claim', () => {
    for (const option of PERMISSION_OPTIONS) {
      expect(isCurrent(reading(null, null), option)).toBe(false)
    }
  })

  it('matches effort and permission on the exact id', () => {
    expect(isCurrent(reading('xhigh', 'Extra high'), { id: 'xhigh', label: 'Extra high' })).toBe(true)
    expect(isCurrent(reading('plan', 'Plan'), { id: 'plan', label: 'Plan' })).toBe(true)
    expect(isCurrent(reading('plan', 'Plan'), { id: 'auto', label: 'Auto' })).toBe(false)
  })

  /*
   * Every row of the model menu now names the model it resolves to rather than
   * its family, so the match is between two display names rather than between a
   * family word and the front of a reading. The four spellings below are the
   * four this app genuinely receives, from four different sources — the CLI's
   * confirmation, its picker, its welcome panel, and the transcript — and they
   * all have to land on the same row.
   */
  it('matches the model however the source happened to spell it', () => {
    const sonnet = { id: 'sonnet', label: 'Sonnet 5' }
    expect(isCurrent(reading('Sonnet 5', 'Sonnet 5'), sonnet)).toBe(true)
    expect(isCurrent(reading('Sonnet 5 (default)', 'Sonnet 5 (default)'), sonnet)).toBe(true)
    expect(isCurrent(reading('Sonnet 5', 'Sonnet 5'), { id: 'haiku', label: 'Haiku 4.5' })).toBe(false)
  })

  it('reads back from an alias in Claude’s settings file too', () => {
    // `modelFromSettings` reports the alias as the value, so the id comparison
    // is what ticks the row on a session that has said nothing at all.
    expect(isCurrent(reading('opus[1m]', 'Opus 5 with 1M context'), { id: 'opus[1m]', label: 'Opus 5 with 1M context' })).toBe(true)
  })

  /*
   * The distinction `Default` used to exist to preserve, now carried by two rows
   * that say which window they are. `Opus 5` and `Opus 5 (1M context)` are
   * different models to be on, and a tick on the wrong one would be a lie about
   * the context window — so the long-context marker has to survive whichever way
   * the source spelled it.
   */
  it('never confuses the 1M-context model with the ordinary one', () => {
    const long = { id: 'opus[1m]', label: 'Opus 5 with 1M context' }
    const plain = { id: 'opus', label: 'Opus 5' }
    for (const spelling of ['Opus 5 (1M context)', 'Opus 5 (1M context) (default)', 'Opus 5 · 1M']) {
      expect(isCurrent(reading(spelling, spelling), long), spelling).toBe(true)
      expect(isCurrent(reading(spelling, spelling), plain), spelling).toBe(false)
    }
    expect(isCurrent(reading('Opus 5', 'Opus 5'), plain)).toBe(true)
    expect(isCurrent(reading('Opus 5', 'Opus 5'), long)).toBe(false)
  })

  /*
   * *"only showing Opus 5 is enough — they can see it inside the dropdown, they
   * don't need to see this long thing with three dots."* The chip is fourteen
   * characters and `Opus 5 with 1M context` is twenty-two, so it was landing as
   * `Opus 5 with 1M…`.
   */
  it('shortens a model name to the chip without losing which window it is', () => {
    // Every spelling this app reads a model under, from the four sources listed
    // on `modelKey`, plus the picker's own policy row.
    expect(shortModelLabel('Opus 5 with 1M context')).toBe('Opus 5 1M')
    expect(shortModelLabel('Opus 5 (1M context)')).toBe('Opus 5 1M')
    expect(shortModelLabel('Opus 5 (1M context) (default)')).toBe('Opus 5 1M')
    expect(shortModelLabel('Opus 5 · 1M')).toBe('Opus 5 1M')
    expect(shortModelLabel('Opus 5')).toBe('Opus 5')
    expect(shortModelLabel('Sonnet 5')).toBe('Sonnet 5')
    expect(shortModelLabel('Haiku 4.5')).toBe('Haiku 4.5')
    expect(shortModelLabel('Opus in plan mode, else Sonnet')).toBe('Opus Plan')

    /*
     * The rule the whole thing turns on: two selections the picker offers
     * separately must not print the same words on the bar. Shortening
     * `Opus 5 with 1M context` all the way to `Opus 5` would leave a reader with
     * no way to tell which of two genuinely different windows they were on.
     */
    expect(shortModelLabel('Opus 5 with 1M context')).not.toBe(shortModelLabel('Opus 5'))
    // And nothing this produces needs an ellipsis: the chip is 14ch.
    for (const row of MODEL_OPTIONS) expect(shortModelLabel(row.label).length).toBeLessThanOrEqual(14)
  })
})


/*
 * `unsupportedProviderNote`'s tests moved with it.
 *
 * It was deleted from `catalog.ts` on 2026-08-19 because it named one vendor on
 * a bar that was showing another. The behaviour it described is still tested —
 * in `SessionControls.test.tsx`, beside the code that now composes the sentence.
 * A test left here for an export that no longer exists is the shape this repo
 * keeps finding: a guard that has stopped guarding, still looking like one.
 */
