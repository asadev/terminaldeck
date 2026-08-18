import { describe, expect, it } from 'vitest'
import capture from './cli-screens.capture.json'
import conpty from './agent-controls.conpty.json'
import {
  aliasForRow,
  foldDefaultRow,
  isTypeableModelValue,
  readModelPicker,
  FALLBACK_MODELS,
  PREVIOUS_MODELS,
} from '../shared/model-catalog'

/**
 * Everything here runs against screens the real CLI drew.
 *
 * `cli-screens.capture.json` is `claude 2.1.234` on this Mac, driven through a
 * pty into the same headless terminal the app reads sessions with;
 * `agent-controls.conpty.json` is the same picker on Windows, captured by an
 * earlier pass. Both are in the repo so that a change to the parsing has to
 * survive two terminals rather than one, and so that nobody has to re-type a
 * screen from memory to add a case.
 */

/** Every screen in the Windows capture, whichever environment block it sits in. */
function windowsShots(): string[] {
  const environments = conpty.environments as Record<string, { shots: Array<{ screen: string }> }>
  return Object.values(environments).flatMap((environment) => environment.shots.map((shot) => shot.screen))
}
describe('the CLI model picker', () => {
  it('reads every row the picker drew, with the model behind each one', () => {
    const rows = readModelPicker(capture.shots.modelPicker)
    expect(rows).not.toBeNull()
    expect(rows?.map((row) => `${row.name} → ${row.model}`)).toEqual([
      'Default (recommended) → Opus 5 with 1M context',
      'Opus (1M context) → Opus 5 with 1M context',
      'Fable → Fable 5',
      'Sonnet → Sonnet 5',
      'Haiku → Haiku 4.5',
      'Opus → Opus 5',
    ])
  })

  it('marks the row the picker ticks, and only that one', () => {
    const rows = readModelPicker(capture.shots.modelPicker) ?? []
    expect(rows.filter((row) => row.current).map((row) => row.name)).toEqual(['Opus'])
  })

  it('marks the account default from the CLI’s own "(recommended)"', () => {
    const rows = readModelPicker(capture.shots.modelPicker) ?? []
    expect(rows.filter((row) => row.recommended).map((row) => row.name)).toEqual(['Default (recommended)'])
  })

  /*
   * The Windows capture is a different terminal, a different tick glyph and a
   * different set of rows — five, with the tick on the first — and it has to
   * parse identically. This is the case that would have caught a parser written
   * against `✔` alone, which is what ConPTY does not draw.
   */
  it('reads the same picker on Windows, where the tick is drawn as √', () => {
    const windowsPicker = windowsShots().find(
      (screen) => screen.includes('Select model') && screen.includes('√'),
    )
    expect(windowsPicker, 'the Windows capture should contain a drawn picker').toBeTruthy()
    const rows = readModelPicker(String(windowsPicker)) ?? []
    expect(rows.map((row) => row.name)).toEqual([
      'Default (recommended)',
      'Opus (1M context)',
      'Fable',
      'Sonnet',
      'Haiku',
    ])
    expect(rows.filter((row) => row.current).map((row) => row.name)).toEqual(['Default (recommended)'])
  })

  it('is not the picker when the picker is not on screen', () => {
    expect(readModelPicker(capture.shots.bootFastOff)).toBeNull()
    expect(readModelPicker(capture.shots.pickerCancelled)).toBeNull()
    expect(readModelPicker(capture.shots.fastOn)).toBeNull()
  })

  /*
   * A numbered list inside an answer is the thing a looser match would swallow.
   * The heading is what separates the two, and this pins that it is required —
   * without it this app would offer somebody's chat reply as the model list.
   */
  it('refuses a numbered list that is not the picker', () => {
    const answer = [
      '❯ what models are there',
      '⏺ There are a few:',
      '    1. Opus                     the big one',
      '    2. Sonnet                   the quick one',
    ].join('\n')
    expect(readModelPicker(answer)).toBeNull()
  })

  it('refuses a half-drawn picker, where only one row has painted', () => {
    const half = ['Select model', '  1. Default (recommended)  Opus 5 with 1M context · Best for everyday'].join('\n')
    expect(readModelPicker(half)).toBeNull()
  })
})

describe('the alias a row is chosen with', () => {
  /*
   * Every expectation below is a command that was typed at `claude 2.1.234` on
   * this machine, with the reply it gave:
   *
   *   /model opus[1m] → Set model to Opus 5 (1M context) and saved as your default
   *   /model opusplan → Set model to Opus in plan mode, else Sonnet and saved as …
   *   /model sonnet   → Set model to Sonnet 5 …
   *
   * `sonnet46` is here as the negative case and it is not hypothetical: it was
   * tried, on the assumption that the CLI's internal alias list was reachable,
   * and answered `Model 'sonnet46' not found`. Aliases come from row names, not
   * from guessing at model numbers.
   */
  it('derives the alias from the row name', () => {
    expect(aliasForRow('Default (recommended)')).toBe('default')
    expect(aliasForRow('Opus (1M context)')).toBe('opus[1m]')
    expect(aliasForRow('Opus ✔')).toBe('opus')
    expect(aliasForRow('Opus Plan')).toBe('opusplan')
    expect(aliasForRow('Fable')).toBe('fable')
    expect(aliasForRow('Sonnet')).toBe('sonnet')
    expect(aliasForRow('Haiku')).toBe('haiku')
  })

  it('produces the aliases the CLI accepted for every row of the real picker', () => {
    const rows = readModelPicker(capture.shots.modelPicker) ?? []
    expect(rows.map((row) => row.alias)).toEqual(['default', 'opus[1m]', 'fable', 'sonnet', 'haiku', 'opus'])
  })
})

describe('folding the Default row away', () => {
  /*
   * His words, watching the list: *"Default, I think, is nothing, because in
   * Claude you don't see anything default — it just says automatically
   * unselected ones, but not as a separate choice."*
   */
  it('drops Default and marks the row it pointed at instead', () => {
    const folded = foldDefaultRow(readModelPicker(capture.shots.modelPicker) ?? [])
    expect(folded.map((row) => row.name)).toEqual(['Opus (1M context)', 'Fable', 'Sonnet', 'Haiku', 'Opus'])
    expect(folded.filter((row) => row.recommended).map((row) => row.name)).toEqual(['Opus (1M context)'])
  })

  it('keeps the selection when Default was the ticked row', () => {
    const windowsPicker = windowsShots().find(
      (screen) => screen.includes('Select model') && screen.includes('√'),
    )
    const folded = foldDefaultRow(readModelPicker(String(windowsPicker)) ?? [])
    expect(folded.map((row) => row.name)).toEqual(['Opus (1M context)', 'Fable', 'Sonnet', 'Haiku'])
    // The tick was on Default; Default resolves to the 1M row, so that is where
    // the tick has to land. A fold that lost it would leave a list with nothing
    // selected — the exact state he objected to.
    expect(folded.filter((row) => row.current).map((row) => row.name)).toEqual(['Opus (1M context)'])
  })

  it('renames rather than deletes a Default that points at nothing else on the list', () => {
    const rows = [
      { alias: 'default', name: 'Default (recommended)', model: 'Something 9', note: '', current: true, recommended: true },
      { alias: 'sonnet', name: 'Sonnet', model: 'Sonnet 5', note: '', current: false, recommended: false },
    ]
    const folded = foldDefaultRow(rows)
    expect(folded.map((row) => row.name)).toEqual(['Something 9', 'Sonnet'])
    expect(folded[0].current).toBe(true)
  })

  it('never leaves a list with no row selected once the CLI has ticked one', () => {
    const rows = readModelPicker(capture.shots.modelPicker) ?? []
    expect(foldDefaultRow(rows).some((row) => row.current)).toBe(true)
  })
})

describe('what may be typed after /model', () => {
  it('accepts the aliases and full ids the CLI answered to', () => {
    for (const value of ['default', 'opus', 'opus[1m]', 'fable', 'sonnet', 'haiku', 'opusplan']) {
      expect(isTypeableModelValue(value), value).toBe(true)
    }
    for (const row of PREVIOUS_MODELS) {
      expect(isTypeableModelValue(row.alias), row.alias).toBe(true)
    }
  })

  /*
   * The shape check is what stands between a model name and somebody's
   * terminal. A space makes a second argument; a return submits a line nobody
   * wrote. Neither may get through.
   */
  it('refuses anything that would become more than one argument', () => {
    for (const value of ['sonnet 5', 'sonnet\r', 'sonnet\nrm -rf /', '/model sonnet', '', ' ', 'a b']) {
      expect(isTypeableModelValue(value), JSON.stringify(value)).toBe(false)
    }
  })
})

describe('the written-down lists', () => {
  it('offers no Default row in the fallback either', () => {
    expect(FALLBACK_MODELS.some((row) => row.alias === 'default')).toBe(false)
  })

  it('names a version on every row, which is the whole complaint', () => {
    /*
     * "Opus 4 should be Opus 5" — a row whose label is just a family name
     * cannot answer that question at all, so no row is allowed to be one.
     *
     * `Opus Plan` is the one exemption and it is the CLI's own wording: it
     * resolves to "Opus in plan mode, else Sonnet", which is a routing rule
     * across two models rather than a model with a version. Pinning a number
     * onto it would mean inventing one.
     */
    for (const row of [...FALLBACK_MODELS, ...PREVIOUS_MODELS]) {
      if (row.alias === 'opusplan') continue
      expect(row.model, row.name).toMatch(/\d/)
    }
  })

  it('does not repeat a model between the two lists', () => {
    const current = new Set(FALLBACK_MODELS.map((row) => row.model))
    for (const row of PREVIOUS_MODELS) expect(current.has(row.model), row.model).toBe(false)
  })
})
