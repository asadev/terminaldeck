import { describe, expect, it } from 'vitest'
import {
  controlName,
  describeControl,
  displayValue,
  unreadLabel,
  unreadNote,
  EFFORT_OPTIONS,
  isCurrent,
  MENU_CONTROLS,
  MODEL_OPTIONS,
  modelOptions,
  optionsFor,
  PERMISSION_OPTIONS,
  PRIMARY_CONTROLS,
  reachOf,
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
})

describe('what the panel holds and what gets a chip', () => {
  it('keeps the two a session reaches for on the box itself', () => {
    // Model changes per task, permission per phase of the work. Effort is set
    // once if ever, and fast mode usually cannot even be read.
    expect(PRIMARY_CONTROLS).toEqual(['model', 'permission'])
  })

  it('gives every control exactly one home, and leaves none homeless', () => {
    /*
     * The rule, and it replaces an assertion that said the opposite — so the
     * reversal is written down here rather than in a commit message.
     *
     * What was pinned before: the panel lists *every* control, chip or no chip.
     * That was the answer to "all the options you have actually removed", where
     * two controls sat behind a button called "More" and nothing on screen
     * named what "More" held.
     *
     * What was then reported, watching the app: "options is having all of the
     * things that we already have here and there. So let's keep everything
     * separate rather than having everything on one page like on options." With
     * the panel open, Model and Permission were on screen twice at once — a
     * chip and a section, the same value, the same keystrokes.
     *
     * The rule that answers both is a partition: every control is in exactly
     * one of the two lists. Nothing is said twice, and — the half the old
     * assertion was really protecting — nothing is in neither list, which is
     * how a control leaves the app while all of its own tests keep passing.
     */
    expect([...PRIMARY_CONTROLS, ...MENU_CONTROLS].sort()).toEqual([...ALL].sort())
    expect(new Set([...PRIMARY_CONTROLS, ...MENU_CONTROLS]).size).toBe(ALL.length)
  })

  it('does not repeat a chip inside the panel that opens beside it', () => {
    // Stated separately from the partition above because this is the complaint
    // itself, and a partition could be satisfied by moving a chip into the
    // panel rather than by not duplicating it.
    for (const control of PRIMARY_CONTROLS) {
      expect(MENU_CONTROLS, `${control} is on the row and in the panel`).not.toContain(control)
    }
  })

  it('keeps the panel worth opening — more than one thing is behind it', () => {
    // A menu holding a single entry is a menu that should have been that entry.
    // If this ever drops to one, fold it out onto the row and delete the panel
    // rather than leaving a button that opens onto one section.
    expect(MENU_CONTROLS.length).toBeGreaterThan(1)
  })

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
   * scope to state and it is worth stating: leaving a higher credit draw
   * switched on by accident is exactly what a missing sentence here costs.
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
