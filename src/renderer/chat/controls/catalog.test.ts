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
  optionsFor,
  PERMISSION_OPTIONS,
  PRIMARY_CONTROLS,
  reachOf,
  sourceNote,
  unsupportedProviderNote,
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

  it('keeps Default and Opus apart, because the CLI does', () => {
    // `/model default` answered "Opus 5 (1M context)"; `/model opus` answered
    // "Opus 5". Collapsing them would silently change the context window.
    const ids = MODEL_OPTIONS.map((option) => option.id)
    expect(ids).toContain('default')
    expect(ids).toContain('opus')
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

  it('says nothing at all about fast mode, which announces no scope', () => {
    expect(reachOf('fast')).toBeNull()
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

  it('matches the model on the family word, since it reads back as a display name', () => {
    expect(isCurrent(reading('Sonnet 5', 'Sonnet 5'), { id: 'sonnet', label: 'Sonnet' })).toBe(true)
    expect(isCurrent(reading('claude-opus-5[1m]', 'Opus 5 · 1M'), { id: 'opus', label: 'Opus' })).toBe(true)
    expect(isCurrent(reading('Sonnet 5', 'Sonnet 5'), { id: 'haiku', label: 'Haiku' })).toBe(false)
  })

  it('gives the CLI\'s "(default)" marker to Default and not to Opus', () => {
    const asDefault = reading('Opus 5 (1M context) (default)', 'Opus 5 (1M context) (default)')
    expect(isCurrent(asDefault, { id: 'default', label: 'Default' })).toBe(true)
    expect(isCurrent(asDefault, { id: 'opus', label: 'Opus' })).toBe(false)
  })
})


describe('an agent CLI this build has not learned', () => {
  it('says nothing about Claude, which is the one it does speak', () => {
    expect(unsupportedProviderNote('claude')).toBeNull()
  })

  it('leaves a session whose CLI is unknown alone, because the screen answers that', () => {
    // `undefined` is an agent started by hand inside a shell session. The main
    // process decides that one from the screen — the markers it matches are
    // Claude Code's own — so pre-empting it here would withdraw the controls
    // from the very case they were extended to cover.
    expect(unsupportedProviderNote(undefined)).toBeNull()
  })

  it('leaves the shell to its own sentence rather than borrowing this one', () => {
    // "There is no model in a shell" and "this build has not learned this CLI's
    // commands" are different facts, and merging them would make the shell case
    // read as an unfinished feature.
    expect(unsupportedProviderNote('shell')).toBeNull()
  })

  it('names Codex and Gemini, and says the mechanism is unestablished rather than absent', () => {
    for (const [provider, name] of [
      ['codex', 'Codex'],
      ['gemini', 'Gemini'],
    ]) {
      const note = unsupportedProviderNote(provider)
      expect(note, provider).toContain(name)
      // Neither could be driven on the machine this was written on — the Codex
      // binary is missing and Gemini stops on an auth picker — so this build
      // has no evidence either way. Claiming they *cannot* do it would be
      // inventing a fact to sound final.
      expect(note, provider).not.toMatch(/cannot|impossible|does not support/i)
      expect(note, provider).toMatch(/has not been shown/i)
    }
  })
})
