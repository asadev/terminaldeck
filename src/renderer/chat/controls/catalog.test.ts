import { describe, expect, it } from 'vitest'
import {
  displayValue,
  EFFORT_OPTIONS,
  isCurrent,
  MODEL_OPTIONS,
  optionsFor,
  PERMISSION_OPTIONS,
  reachOf,
  sourceNote,
  type ControlReading,
} from './catalog'

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

describe('how far a change reaches', () => {
  it('says permission is session-only and effort is not', () => {
    // The CLI persists effort and model ("saved as your default for new
    // sessions") but logs that a runtime permission mode is session-scoped.
    expect(reachOf('permission')).toMatch(/session only/i)
    expect(reachOf('effort')).toMatch(/default for new sessions/i)
    expect(reachOf('model')).toMatch(/default for new sessions/i)
  })
})

describe('never showing a value that was not read', () => {
  it('says Unknown rather than picking something plausible', () => {
    expect(displayValue({ value: null, label: null, source: null })).toBe('Unknown')
    expect(displayValue(undefined)).toBe('Unknown')
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
