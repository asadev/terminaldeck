import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { CodeEntry, addedBy, digitAt, symbolFor, typedInto, type CodeEntryState } from './CodeEntry'
import { CODE_LENGTH, normaliseCode } from '../../shared/short-code'

/**
 * The field a code from the other machine is typed into.
 *
 * Everything worth checking about it is what a keystroke *means*, and every one
 * of those is a pure function — so this suite is mostly calls rather than
 * clicks, which is what makes the paste cases checkable at all in a test
 * environment with no DOM.
 *
 * The rule the whole file is written around: nothing here knows what a code is
 * made of. It asks `shared/short-code.ts`. So these tests are written in terms
 * of what that module accepts rather than in terms of digits, and the ones that
 * do name a digit are naming an example rather than a rule.
 */

function state(over: Partial<CodeEntryState> = {}): CodeEntryState {
  return { digits: '', busy: false, error: null, blocked: null, ...over }
}

function render(over: Partial<CodeEntryState> = {}, wired = true): string {
  return renderToStaticMarkup(
    <CodeEntry state={state(over)} wired={wired} onDigits={() => {}} onSubmit={() => {}} />,
  )
}

describe('what a keystroke means', () => {
  it('takes a character a code can contain, and refuses one it cannot', () => {
    expect(symbolFor('4')).toBe('4')
    expect(symbolFor('0')).toBe('0')
    // A letter is a typo. It is not folded into a digit that looks like it —
    // that would be a *different valid code*, silently.
    expect(symbolFor('O')).toBeNull()
    expect(symbolFor('l')).toBeNull()
    expect(symbolFor(' ')).toBeNull()
    expect(symbolFor('-')).toBeNull()
    expect(symbolFor('')).toBeNull()
    expect(symbolFor('42')).toBeNull()
  })

  it('asks the shared module rather than holding its own alphabet', () => {
    // The proof that it asks: every character the format accepts round-trips,
    // and nothing else does. If `short-code.ts` changes its alphabet again this
    // stays true without an edit here — which is the whole point.
    for (const character of '0123456789') {
      expect(symbolFor(character), character).toBe(character)
      expect(normaliseCode(character.repeat(CODE_LENGTH))).not.toBeNull()
    }
  })
})

describe('typing into the boxes', () => {
  it('fills the box it was typed into and moves on', () => {
    expect(typedInto('', 0, '4')).toEqual({ digits: '4', focus: 1 })
    expect(typedInto('48', 2, '2')).toEqual({ digits: '482', focus: 3 })
  })

  it('does not slide a digit typed into a later box down to the front', () => {
    // The bug this pins: a caret placed in the fourth box of an empty field
    // producing a one-character string, which then renders as the *first*
    // digit. The space is what an untyped box holds.
    const typed = typedInto('', 3, '5')
    expect(typed.digits).toBe('   5')
    expect(digitAt(typed.digits, 0)).toBe('')
    expect(digitAt(typed.digits, 3)).toBe('5')
    // And a gapped code is incomplete rather than short: the spaces are noise
    // to `normaliseCode`, so it reads as one digit, not as a code.
    expect(normaliseCode(typed.digits)).toBeNull()
  })

  it('replaces the digit in a box that already had one', () => {
    expect(typedInto('482913', 0, '7')).toEqual({ digits: '782913', focus: 1 })
  })

  it('spreads a paste across the boxes, separators and all', () => {
    // `482 913`, `482-913` and `482913` are the same code — because
    // `normaliseCode` says a separator is noise, not because this file does.
    expect(typedInto('', 0, '482 913').digits).toBe('482913')
    expect(typedInto('', 0, '482-913').digits).toBe('482913')
    expect(typedInto('', 0, '482913').digits).toBe('482913')
  })

  it('never holds more than a code', () => {
    const typed = typedInto('', 0, '4829134444')
    expect(typed.digits).toHaveLength(CODE_LENGTH)
    // The caret stops at the last box rather than wrapping to the first, which
    // would silently overwrite the digit that is already there.
    expect(typed.focus).toBe(CODE_LENGTH - 1)
  })

  it('ignores a keystroke that is not part of a code, rather than clearing anything', () => {
    expect(typedInto('482', 3, 'x')).toEqual({ digits: '482', focus: 3 })
    expect(typedInto('482', 3, '')).toEqual({ digits: '482', focus: 3 })
  })

  it('reads one keystroke out of a box that kept the digit it already had', () => {
    // A click that puts the caret *beside* the digit rather than over it gives
    // a two-character value for one press. Writing both would move a digit the
    // reader never typed into the next box.
    expect(addedBy('4', '48')).toBe('8')
    expect(addedBy('4', '84')).toBe('8')
    expect(addedBy('', '4')).toBe('4')
    expect(addedBy('4', '8')).toBe('8')
  })
})

describe('the field itself', () => {
  it('draws one box per digit, numeric, with nothing dressed up as a value', () => {
    const html = render()
    expect(html.match(/class="machine-entry-box"/g)).toHaveLength(CODE_LENGTH)
    expect(html).toContain('inputMode="numeric"')
    // The old single field's placeholder was a real-looking example code in the
    // same mono face, so an empty field read as a filled one — and the fake
    // code was typeable.
    expect(html).not.toContain('placeholder')
    expect(html).toContain(`${CODE_LENGTH} digits`)
  })

  it('offers the code a device has just shown, on the first box only', () => {
    const html = render()
    expect(html.match(/autoComplete="one-time-code"/g)).toHaveLength(1)
  })

  it('will not submit an incomplete code', () => {
    expect(render()).toMatch(/<button[^>]*disabled[^>]*>Pair<\/button>/)
    expect(render({ digits: '48291' })).toMatch(/<button[^>]*disabled[^>]*>Pair<\/button>/)
    // A gap counts as incomplete, which is why completeness is asked of
    // `normaliseCode` rather than of the string's length.
    expect(render({ digits: '4829 3' })).toMatch(/<button[^>]*disabled[^>]*>Pair<\/button>/)
    expect(render({ digits: '482913' })).toMatch(
      /<button(?![^>]*disabled)[^>]*>Pair<\/button>/,
    )
  })

  it('shows the digits it has been given, in order', () => {
    const html = render({ digits: '482913' })
    expect(html.match(/value="(\d)"/g)).toEqual([
      'value="4"',
      'value="8"',
      'value="2"',
      'value="9"',
      'value="1"',
      'value="3"',
    ])
  })

  it('prints the refusal it was given, in the far machine’s words', () => {
    const html = render({
      digits: '482913',
      error: 'No machine is showing that code. Check the digits — they last a minute.',
    })
    expect(html).toContain('No machine is showing that code')
    expect(html).toContain('aria-invalid="true"')
  })

  it('goes quiet with a reason rather than failing on submit', () => {
    // Looking a code up means asking the relay, so a desktop whose link is down
    // can type a perfect code and get nowhere. Verbatim, because that sentence
    // is the main process's and it says what to do.
    const html = render({
      blocked: 'This machine is not connected to the relay yet, so it cannot show or read a pairing code.',
    })
    expect(html).toContain('not connected to the relay yet')
    expect(html).toMatch(/<input[^>]*disabled/)
  })

  it('says so when the build has no machine channels at all', () => {
    const html = render({}, false)
    expect(html).toContain('cannot pair with another desktop')
    expect(html).toContain('not in its preload')
    expect(html).toMatch(/<input[^>]*disabled/)
  })

  it('goes quiet while an attempt is in flight, and says which', () => {
    const html = render({ digits: '482913', busy: true })
    expect(html).toContain('Pairing…')
    expect(html).toMatch(/<button[^>]*disabled/)
  })
})
