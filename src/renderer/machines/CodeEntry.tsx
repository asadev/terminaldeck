import { useRef, type KeyboardEvent } from 'react'
import { Button, Notice } from '../settings/controls'
import { CODE_LENGTH, normaliseCode } from '../../shared/short-code'

/**
 * Typing the code the *other* machine is showing.
 *
 * This is the entry side of pairing, and it is the half that was missing from
 * the panel a phone pairs on: that panel could only ever hand a code out. A
 * second desktop has no camera and nothing to scan, so the only way it joins is
 * that somebody reads six digits off one screen and types them into this one.
 *
 * ## Why one box per digit
 *
 * The code is read off a screen an arm's length away and typed without looking
 * down. Six boxes give the two things a single field cannot: the count is
 * visible before a key is pressed — you can see how many digits are wanted — and
 * a mistyped digit is one box to fix rather than a string to re-select. The
 * focus moves on its own because the alternative is pressing Tab five times
 * while a sixty-second code runs down.
 *
 * ## What it accepts, and why the rule is not written here
 *
 * Every keystroke goes through {@link symbolFor}, which asks
 * `shared/short-code.ts` itself whether a character belongs in a code. Nothing
 * in this file knows that a code is digits, that it is six long, or that a space
 * is noise — those facts have moved once already (eight Crockford characters
 * with a hyphen, then six digits with nothing), and every place that had its own
 * copy of them was wrong for a release. A paste of `482 913`, `482-913` or
 * `482913` is the same code, because `normaliseCode` says so.
 *
 * A character that is not part of a code — a letter, a punctuation mark — simply
 * does not appear. That is deliberate silence rather than a missing message: the
 * field is `inputMode="numeric"`, so on the device where this is easiest to get
 * wrong the keyboard has nothing else on it, and a red line under a field
 * because somebody's palm hit a key is noise about a keystroke that never
 * reached anything.
 *
 * The errors that *are* printed are the ones that cost something: a code that no
 * machine is showing, one that has run out, one the far machine refused. Those
 * come back from the main process in its own words and are printed verbatim —
 * `pairWithCode` writes them to say what to do next.
 */

/* -------------------------------------------------------------------------- */
/* What a keystroke means                                                      */
/* -------------------------------------------------------------------------- */

/**
 * One typed character as the symbol it stands for, or null when it is not one.
 *
 * The trick is the point: `normaliseCode` is the only thing allowed to know what
 * a code is made of, and it will only answer about a *whole* code — so this asks
 * it about a whole code made of nothing but this character. If the answer is
 * null the character cannot appear in a code at all; if it is a code, its first
 * character is what this one normalises to, and a formatted code always starts
 * with a symbol rather than a separator.
 *
 * Written this way so that the day the format changes again — grouping, a
 * different alphabet, a different length — this file needs no edit at all.
 */
export function symbolFor(character: string): string | null {
  if (character.length !== 1) return null
  const probe = normaliseCode(character.repeat(CODE_LENGTH))
  return probe === null ? null : (probe[0] ?? null)
}

/**
 * What the boxes hold after `raw` is typed or pasted into box `at`.
 *
 * Returns where the caret should end up as well, because those are one decision:
 * a single digit advances one box, a pasted code fills from where it landed and
 * leaves the caret after the last digit it wrote. Both are clamped to the last
 * box rather than wrapping — there is nowhere after the sixth digit to go, and a
 * caret that jumped back to the first box would silently overwrite it.
 *
 * Pure, and exported, because this is the whole behaviour of the field: every
 * case worth checking (a digit, a letter, a paste with separators in it, a paste
 * longer than the code) is a call rather than a click.
 */
export function typedInto(
  digits: string,
  at: number,
  raw: string,
): { digits: string; focus: number } {
  const accepted = [...raw].map(symbolFor).filter((symbol): symbol is string => symbol !== null)
  if (accepted.length === 0) return { digits, focus: at }
  // Padded first, and the padding stays: typing into the fourth box of an empty
  // field must not produce a one-character string that then reads as the *first*
  // digit. A space is what an untyped box holds — `symbolFor` refuses one, so it
  // can only ever have come from here — and `normaliseCode` drops it as noise,
  // which is why a gapped code still reads as incomplete rather than as a short
  // one.
  const padded = digits.padEnd(CODE_LENGTH, ' ')
  const next = (padded.slice(0, at) + accepted.join('') + padded.slice(at + accepted.length))
    .slice(0, CODE_LENGTH)
    .trimEnd()
  return { digits: next, focus: Math.min(at + accepted.length, CODE_LENGTH - 1) }
}

/**
 * The characters a change event actually added to a box that already held one.
 *
 * A controlled one-character box does not always come back one character long.
 * Focusing selects what is there, so a keystroke usually replaces it — but a
 * click that puts the caret *beside* the digit rather than over it produces
 * `48` for one press of `8`, and writing both would move a digit the reader
 * never typed into the box next door.
 *
 * Only ever called for the piecemeal case: a paste carrying a whole code is
 * recognised as one before this is reached, so the ambiguity between "pasted a
 * code starting with the digit already here" and "typed after it" never arises.
 */
export function addedBy(previous: string, raw: string): string {
  if (previous === '' || raw.length <= 1) return raw
  if (raw.startsWith(previous)) return raw.slice(previous.length)
  if (raw.endsWith(previous)) return raw.slice(0, -previous.length)
  return raw
}

/**
 * What box `index` shows: a digit, or nothing.
 *
 * The padding above can leave a space in a box somebody skipped past, and a
 * space rendered as a value is a box that looks empty and is not — it would
 * refuse the caret's `select()` and read as an untyped box to everything except
 * the string. Both readers of the state go through here so there is one answer
 * to "is this box empty".
 */
export function digitAt(digits: string, index: number): string {
  const character = digits[index] ?? ''
  return character === ' ' ? '' : character
}

/** Everything the field draws, and nothing it decides. */
export interface CodeEntryState {
  /** What has been typed so far, canonical symbols, shorter than a whole code. */
  digits: string
  /** A pairing attempt is in flight. */
  busy: boolean
  /**
   * Why the last attempt failed, in the words of whatever refused it. Null
   * before the first attempt and cleared by the next keystroke — an error about
   * a code that has since been retyped is an error about nothing.
   */
  error: string | null
  /**
   * Why this machine cannot look a code up at all, from `machines:list`.
   *
   * Its own sentence, printed verbatim: finding the machine behind a code means
   * asking the relay, so a desktop whose relay link is down can type a perfect
   * code and get nowhere. The field goes quiet with the sentence beside it
   * rather than staying live and failing on submit.
   */
  blocked: string | null
}

export interface CodeEntryProps {
  state: CodeEntryState
  /** True when this build's preload carries the machine channels at all. */
  wired: boolean
  onDigits(next: string): void
  onSubmit(): void
}

export function CodeEntry({ state, wired, onDigits, onSubmit }: CodeEntryProps) {
  const boxes = useRef<Array<HTMLInputElement | null>>([])
  const complete = normaliseCode(state.digits) !== null
  const disabled = state.busy || state.blocked !== null || !wired

  /** Move the caret without touching the value. Guarded: there is no DOM in tests. */
  const focus = (index: number): void => {
    const box = boxes.current[index]
    if (box) {
      box.focus()
      box.select()
    }
  }

  const onKeyDown = (index: number) => (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Backspace') {
      // Backspace in an empty box deletes the digit *before* it and lands there,
      // which is what the same key does in a single field. Without this, holding
      // it clears one box and then does nothing at all.
      if (digitAt(state.digits, index) === '') {
        if (index === 0) return
        event.preventDefault()
        onDigits(state.digits.slice(0, index - 1))
        focus(index - 1)
      }
      return
    }
    if (event.key === 'ArrowLeft' && index > 0) {
      event.preventDefault()
      focus(index - 1)
    }
    if (event.key === 'ArrowRight' && index < CODE_LENGTH - 1) {
      event.preventDefault()
      focus(index + 1)
    }
  }

  return (
    <form
      className="machine-entry"
      onSubmit={(event) => {
        event.preventDefault()
        onSubmit()
      }}
    >
      <div
        className="machine-entry-boxes"
        role="group"
        aria-label={`Pairing code from the other machine, ${CODE_LENGTH} digits`}
      >
        {Array.from({ length: CODE_LENGTH }, (_, index) => (
          <input
            key={index}
            ref={(element) => {
              boxes.current[index] = element
            }}
            className="machine-entry-box"
            value={digitAt(state.digits, index)}
            // Numeric rather than `type="number"`: a number field brings
            // spinners, accepts `1e4` and drops leading zeros, and a code is a
            // string of digits rather than a quantity. `one-time-code` is what
            // lets a phone or a Mac offer a code it has just seen.
            inputMode="numeric"
            autoComplete={index === 0 ? 'one-time-code' : 'off'}
            // No `maxLength`. It is the obvious thing to put on a one-character
            // box and it silently breaks the paste: a code copied out of a
            // message arrives as `482 913`, and a field capped at the length of
            // a code would hand this `482 91` — a valid-looking five-digit
            // string with the last digit cut off. The value is controlled, so
            // whatever arrives is replaced on the next render anyway.
            spellCheck={false}
            disabled={disabled}
            title={state.blocked ?? undefined}
            aria-invalid={state.error !== null}
            onChange={(event) => {
              const raw = event.target.value
              // A whole code arriving in one event — pasted, or filled in by the
              // OS from a message — is the code, whichever box it landed in.
              // Asking `normaliseCode` rather than counting characters is what
              // makes `482 913` and `482913` the same paste.
              const whole = normaliseCode(raw)
              if (whole !== null) {
                onDigits(whole)
                focus(CODE_LENGTH - 1)
                return
              }
              const typed = typedInto(
                state.digits,
                index,
                addedBy(digitAt(state.digits, index), raw),
              )
              if (typed.digits === state.digits) return
              onDigits(typed.digits)
              focus(typed.focus)
            }}
            onKeyDown={onKeyDown(index)}
            onFocus={(event) => event.target.select()}
          />
        ))}
      </div>

      <Button type="submit" tone="primary" disabled={disabled || !complete}>
        {state.busy ? 'Pairing…' : 'Pair'}
      </Button>

      {!wired && (
        <Notice tone="warn">
          This build cannot pair with another desktop. Restart the app.
        </Notice>
      )}
      {state.blocked !== null && <Notice tone="warn">{state.blocked}</Notice>}
      {state.error !== null && <Notice tone="error">{state.error}</Notice>}
    </form>
  )
}
