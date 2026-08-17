/**
 * The one number in this client that can make the app unusable if it is wrong.
 *
 * Two failures are being designed against, and neither is hypothetical in this
 * codebase. A size below the floor makes a `1`, an `l` and an `I` the same shape
 * — in a terminal, where the whole promise is that the characters are exact — and
 * leaves somebody unable to read the settings row that would let them fix it. A
 * size the emulator will accept but the *protocol* will not is worse: `fit`
 * computes a column count from it, and a `resize` frame outside the protocol's
 * range is refused by the server, which closes the socket over a font-size
 * setting. `terminal.ts` says so in its own header.
 *
 * So there is one clamp and every path goes through it, including the read — a
 * value written by a build with different bounds, or typed into a devtools
 * console, is folded back inside on the way out.
 */

import { describe, expect, it } from 'vitest'
import { memoryStorage, type StorageLike } from './remember'
import {
  MAX_TEXT_SIZE,
  MIN_TEXT_SIZE,
  STANDARD_TEXT_SIZE,
  TEXT_SIZE_KEY,
  canGoLarger,
  canGoSmaller,
  clampTextSize,
  largerText,
  readTextSize,
  smallerText,
  textSizeLabel,
  writeTextSize,
} from './text-size'

/** A store that refuses everything, the way Safari does in private mode. */
function refusing(): StorageLike {
  return {
    getItem: () => {
      throw new Error('denied')
    },
    setItem: () => {
      throw new Error('denied')
    },
    removeItem: () => {
      throw new Error('denied')
    },
  }
}

describe('the bounds', () => {
  it('keeps the terminal inside what the protocol and the eye both allow', () => {
    expect(clampTextSize(2)).toBe(MIN_TEXT_SIZE)
    expect(clampTextSize(400)).toBe(MAX_TEXT_SIZE)
    // Whole pixels only. A fractional font size gives a fractional cell width, and
    // eighty of those is a column count that rounds differently on two machines.
    expect(clampTextSize(13.6)).toBe(14)
    // A value that is not a number at all is the standard rather than NaN, which
    // would reach xterm and paint nothing.
    expect(clampTextSize(Number.NaN)).toBe(STANDARD_TEXT_SIZE)
  })

  it('steps by one and stops at each end', () => {
    expect(largerText(STANDARD_TEXT_SIZE)).toBe(STANDARD_TEXT_SIZE + 1)
    expect(smallerText(STANDARD_TEXT_SIZE)).toBe(STANDARD_TEXT_SIZE - 1)
    expect(largerText(MAX_TEXT_SIZE)).toBe(MAX_TEXT_SIZE)
    expect(smallerText(MIN_TEXT_SIZE)).toBe(MIN_TEXT_SIZE)
  })

  it('says when a control has nothing left to do, so it can be disabled', () => {
    // A button that still lights up under a finger while refusing the press is the
    // small lie that makes people tap four times — the same rule `.button:disabled`
    // in the stylesheet was written for.
    expect(canGoLarger(MAX_TEXT_SIZE)).toBe(false)
    expect(canGoSmaller(MIN_TEXT_SIZE)).toBe(false)
    expect(canGoLarger(STANDARD_TEXT_SIZE)).toBe(true)
    expect(canGoSmaller(STANDARD_TEXT_SIZE)).toBe(true)
  })

  it('names the unit, because a bare number means nothing', () => {
    expect(textSizeLabel(13)).toBe('13 px')
    // `px` and not the phone's `pt`: it is the unit the emulator is configured in,
    // and a browser has no points.
    expect(textSizeLabel(400)).toBe(`${MAX_TEXT_SIZE} px`)
  })
})

describe('the store', () => {
  it('starts at what this client has always drawn at', () => {
    expect(readTextSize(memoryStorage())).toBe(STANDARD_TEXT_SIZE)
    expect(STANDARD_TEXT_SIZE).toBe(13)
  })

  it('round-trips a chosen size', () => {
    const storage = memoryStorage()
    writeTextSize(storage, 18)
    expect(readTextSize(storage)).toBe(18)
  })

  it('folds a stored value from outside the bounds back inside', () => {
    // The failure this exists to stop: a one-pixel terminal that somebody then
    // cannot read well enough to find the control that fixes it.
    const storage = memoryStorage()
    storage.setItem(TEXT_SIZE_KEY, '1')
    expect(readTextSize(storage)).toBe(MIN_TEXT_SIZE)
    storage.setItem(TEXT_SIZE_KEY, 'enormous')
    expect(readTextSize(storage)).toBe(STANDARD_TEXT_SIZE)
  })

  it('treats a store that throws as an unanswered question', () => {
    // Safari in private mode throws rather than returning null, and a client that
    // let that reach the caller would fail to open a terminal at all.
    expect(readTextSize(refusing())).toBe(STANDARD_TEXT_SIZE)
    expect(() => writeTextSize(refusing(), 16)).not.toThrow()
  })
})
