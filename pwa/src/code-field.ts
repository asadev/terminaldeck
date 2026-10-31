/**
 * The six-digit field, as attributes rather than as markup.
 *
 * ## Why this is its own module and not four lines in `pairScreen`
 *
 * Because every one of those attributes is a decision that is invisible once it
 * is right and is only ever noticed when it is wrong — on a phone, by somebody
 * who cannot report it as anything more specific than "the keyboard was wrong".
 * `main.ts` builds its whole UI imperatively against a real DOM and has no test
 * that can render it, so a value in there is a value nothing checks.
 *
 * Here it is a plain object, and `code-field.test.ts` asserts each attribute
 * with the reason attached. Undoing one of them fails a test rather than
 * changing what a keypad looks like in somebody's hand.
 *
 * ## The four that matter, and what each of them prevents
 *
 * **`type: 'text'` with `inputMode: 'numeric'`**, never `type: 'number'`. A
 * number input strips leading zeros, shows a spinner, and on several browsers
 * refuses a paste that is not a valid number. `000042` is a perfectly good
 * pairing code and all three of those destroy it. `inputMode` is what actually
 * raises the keypad on iOS and Android; the input's *type* is what decides
 * whether the string survives.
 *
 * **`numeric` rather than `tel` or `decimal`.** `tel` is the other keypad people
 * reach for and it carries `+`, `*`, `#` and a pause key on iOS, none of which
 * belong under a pairing code. `decimal` adds a separator that would only ever
 * be a typo here.
 *
 * **`autocomplete: 'one-time-code'`.** iOS reads an SMS or a password manager's
 * six-digit field with it and offers the code above the keyboard. It costs one
 * attribute and is exactly what this field is.
 *
 * **`maxLength` at six.** Not validation — `normaliseCode` is validation, and an
 * attribute is not a check. It is what stops a seventh digit landing in a field
 * that already auto-submitted, so a slow tap after the code has gone does not
 * produce a field the person has to clear before they can try again.
 */

import { CODE_LENGTH } from '../../src/shared/short-code'

/**
 * The parts of an `HTMLInputElement` this touches.
 *
 * Structural rather than the DOM type, so the test can hand it a plain object
 * and read the result back. A real `HTMLInputElement` satisfies it, which is the
 * whole trick: `main.ts` passes one and nothing has to be mocked at the call
 * site.
 */
export interface CodeFieldLike {
  type: string
  inputMode: string
  autocomplete: string
  pattern: string
  maxLength: number
  placeholder: string
  autocapitalize: string
  spellcheck: boolean
}

/** Turn an input into the pairing-code field. Returns it, for chaining. */
export function asCodeField<T extends CodeFieldLike>(field: T): T {
  field.type = 'text'
  field.inputMode = 'numeric'
  field.autocomplete = 'one-time-code'
  // A hint some browsers use to filter keystrokes. `normaliseCode` is what
  // actually decides; this only stops a letter appearing under the person's
  // finger on a keyboard that has one.
  field.pattern = '[0-9]*'
  field.maxLength = CODE_LENGTH
  // Six zeroes rather than an example code. An example gets typed in — which is
  // a thing that has happened on this product's other screens — and six zeroes
  // is a shape rather than a value.
  field.placeholder = '0'.repeat(CODE_LENGTH)
  field.autocapitalize = 'off'
  field.spellcheck = false
  return field
}
