import { describe, expect, it, vi } from 'vitest'
import { PHYSICAL_KEYBOARD_QUERY, watchPhysicalKeyboard, type MediaQueryLike } from './physical-keyboard'

/**
 * The key bar is furniture for a device with no keys.
 *
 * These pin the decision itself, and one of them pins the *string* — because the
 * failure mode this module exists to prevent is somebody swapping the media
 * query for a user-agent test, and behaviour assertions alone would keep passing
 * while that happened.
 */

function stubQuery(matches: boolean): MediaQueryLike & { fire(next: boolean): void; listeners: number } {
  const listeners = new Set<(event: { matches: boolean }) => void>()
  return {
    matches,
    addEventListener: (_type, listener) => {
      listeners.add(listener)
    },
    removeEventListener: (_type, listener) => {
      listeners.delete(listener)
    },
    fire(next: boolean): void {
      for (const listener of [...listeners]) listener({ matches: next })
    },
    get listeners(): number {
      return listeners.size
    },
  }
}

describe('whether the on-screen key row is worth its space', () => {
  it('asks about the input hardware, not about the browser', () => {
    // Both halves matter. `pointer: fine` alone is true of an Apple Pencil,
    // which comes with no Esc key; `hover: hover` is what says there is a cursor
    // living on the screen rather than a finger that exists while it touches.
    expect(PHYSICAL_KEYBOARD_QUERY).toBe('(hover: hover) and (pointer: fine)')
  })

  it('drops the row on a machine with a mouse and a keyboard', () => {
    const seen: string[] = []
    const fit = watchPhysicalKeyboard((query) => {
      seen.push(query)
      return stubQuery(true)
    }, vi.fn())
    expect(fit.wanted).toBe(false)
    expect(seen).toEqual([PHYSICAL_KEYBOARD_QUERY])
  })

  it('keeps the row on a phone', () => {
    expect(watchPhysicalKeyboard(() => stubQuery(false), vi.fn()).wanted).toBe(true)
  })

  it('brings the row back when an iPad leaves its keyboard', () => {
    // The reason this is watched rather than read once. Read at startup only, a
    // tablet undocked mid-session is a terminal with no way to send Ctrl+C.
    const query = stubQuery(true)
    const onChange = vi.fn()
    const fit = watchPhysicalKeyboard(() => query, onChange)
    expect(fit.wanted).toBe(false)

    query.fire(false)
    expect(fit.wanted).toBe(true)
    expect(onChange).toHaveBeenCalledWith(true)

    query.fire(true)
    expect(fit.wanted).toBe(false)
    expect(onChange).toHaveBeenLastCalledWith(false)
  })

  it('does not tell the caller about a change that changed nothing', () => {
    // The caller answers this by rebuilding the terminal's box, which loses
    // focus and reflows scrollback. A query can fire for something it does not
    // read — a second pointer appearing beside an existing mouse.
    const query = stubQuery(true)
    const onChange = vi.fn()
    watchPhysicalKeyboard(() => query, onChange)
    query.fire(true)
    expect(onChange).not.toHaveBeenCalled()
  })

  it('stops listening when it is told to, and can be told twice', () => {
    const query = stubQuery(true)
    const onChange = vi.fn()
    const fit = watchPhysicalKeyboard(() => query, onChange)
    expect(query.listeners).toBe(1)
    fit.stop()
    fit.stop()
    expect(query.listeners).toBe(0)
    query.fire(false)
    expect(onChange).not.toHaveBeenCalled()
  })

  it('keeps the row when the question cannot be asked at all', () => {
    // The two ways to be wrong are not symmetrical: a redundant row on a laptop
    // is eleven buttons somebody ignores, and a missing row on a phone is a
    // terminal that cannot interrupt a runaway process.
    expect(watchPhysicalKeyboard(undefined, vi.fn()).wanted).toBe(true)
    expect(
      watchPhysicalKeyboard(() => {
        throw new Error('unsupported query')
      }, vi.fn()).wanted,
    ).toBe(true)
  })

  it('has a stop that is safe on a browser that never listened', () => {
    expect(() => watchPhysicalKeyboard(undefined, vi.fn()).stop()).not.toThrow()
  })
})
